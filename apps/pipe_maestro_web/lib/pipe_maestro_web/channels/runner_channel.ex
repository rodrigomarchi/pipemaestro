defmodule PipeMaestroWeb.RunnerChannel do
  @moduledoc """
  One runner's channel (`runner:<id>`). Joining announces the runner
  (`PipeMaestroProtocol.Hello`): the details are stored and the runner
  is tracked as online in its workspace until the channel ends. A runner not
  on this control plane's version is refused (`"outdated"`, with where to
  download the current one: `PipeMaestroWeb.RunnerUpdate`).

  Jobs travel on it too (`PipeMaestroProtocol.Job`): the channel pushes
  `job:assign` and `job:cancel` as the runner's jobs are created and canceled,
  hands over the queued ones again on every join, and stores what the runner
  reports (`job:started`, `job:event`, `job:finished`) and passes on what
  the agent is writing (`job:delta`). A job of a task's
  stage carries its context (directory, worktree, schema, artifact path), and
  every job but a proposal the workspace's secrets (`PipeMaestro.Secrets`),
  added only on the way out, and, from a task of a linked repository, the
  git credential of its connection, renewed with `job:credential` before it
  expires (ADR 0037).

  So do the task worktrees (`PipeMaestroProtocol.Worktree`): the channel
  pushes `worktree:remove` when someone asks for a task's worktree to go, and
  the unconfirmed ones again on every join; the runner answers
  `worktree:removed` and reports the space they take (`worktree:usage`).

  The runner also sends `runner:directories` when the code directories it
  offers change while it is online.

  Each accepted join opens a session (`PipeMaestro.RunnerTelemetry`), closed
  with the reason the channel ended; a refused join is recorded as a session
  that ends as it starts (ADR 0039).
  """
  use Phoenix.Channel

  alias PipeMaestro.{Integrations, Jobs, Runners, RunnerTelemetry, Secrets, Tasks}
  alias PipeMaestro.Jobs.Event
  alias PipeMaestroProtocol.{Hello, Job, Worktree}
  alias PipeMaestroWeb.{RunnerStatus, RunnerUpdate}

  @impl true
  def join("runner:" <> runner_id, payload, socket) do
    runner = socket.assigns.runner

    with true <- runner_id == runner.id,
         {:ok, hello} <- Hello.from_map(payload),
         :ok <- Runners.version_check(hello.runner_version) do
      {:ok, runner} = Runners.record_hello(runner, hello)
      session = RunnerTelemetry.open_session(runner)
      send(self(), {:after_join, hello})

      {:ok,
       %{"runner_id" => runner.id, "name" => runner.name, "workspace" => runner.workspace.name},
       assign(socket, runner: runner, joined: true, session_id: session.id)}
    else
      false ->
        {:error, %{"reason" => "unauthorized"}}

      {:error, reason} ->
        refused(runner, "invalid_hello", payload)
        {:error, %{"reason" => "invalid_hello", "detail" => reason}}

      # Only the refusal is recorded: the runner stays offline until it runs
      # the current version.
      {:outdated, expected} ->
        refused(runner, "outdated", payload)
        {:error, RunnerUpdate.refusal(payload["runner_version"], expected)}
    end
  end

  defp refused(runner, reason, payload) do
    version = if is_map(payload), do: payload["runner_version"]
    RunnerTelemetry.record_refusal(runner, reason, version)
  end

  @impl true
  def handle_info({:after_join, hello}, socket) do
    runner = socket.assigns.runner
    {:ok, _ref} = RunnerStatus.track(self(), runner)
    RunnerStatus.notify_changed(runner.workspace_id)

    :ok = Jobs.subscribe({:runner, runner.id})
    for job <- Jobs.reconcile(runner, hello.running_job_ids), do: push_assign(socket, job)

    for job_id <- Jobs.ended_among(runner, hello.running_job_ids),
        do: push(socket, Job.cancel_event(), %{"job_id" => job_id})

    for task <- Tasks.pending_worktree_removals(runner),
        do: push(socket, Worktree.remove_event(), Tasks.removal(task))

    {:noreply, socket}
  end

  def handle_info({:worktree_remove, removal}, socket) do
    push(socket, Worktree.remove_event(), removal)
    {:noreply, socket}
  end

  def handle_info({:job_assign, job}, socket) do
    push_assign(socket, job)
    {:noreply, socket}
  end

  # A running job's credential, renewed before it expires.
  def handle_info({:renew_credential, job_id}, socket) do
    with %{} = job <- Jobs.get(job_id),
         %{} = credential <- Integrations.git_credential_for_job(job) do
      push(socket, Job.credential_event(), %{"job_id" => job_id, "git_credential" => credential})
      schedule_renewal(job_id, credential)
    end

    {:noreply, socket}
  end

  def handle_info({:job_cancel, job_id}, socket) do
    push(socket, Job.cancel_event(), %{"job_id" => job_id})
    {:noreply, socket}
  end

  @impl true
  def handle_in("job:started", %{"job_id" => job_id}, socket) do
    socket.assigns.runner |> Jobs.mark_started(job_id) |> reply_to(socket)
  end

  # A rate limit is the runner's account's: the screens showing runners reload.
  def handle_in("job:event", %{"job_id" => job_id} = payload, socket) do
    runner = socket.assigns.runner
    result = Jobs.append_event(runner, job_id, payload)

    with {:ok, %Event{type: "rate_limit"}} <- result,
         do: RunnerStatus.notify_changed(runner.workspace_id)

    reply_to(result, socket)
  end

  # What the agent is writing: passed on, never answered (the runner does not
  # wait for it).
  def handle_in("job:delta", %{"job_id" => job_id, "text" => text}, socket)
      when is_binary(job_id) and is_binary(text) do
    _relayed = Jobs.relay_delta(socket.assigns.runner, job_id, String.slice(text, -4_000, 4_000))
    {:noreply, socket}
  end

  def handle_in("job:finished", %{"job_id" => job_id} = payload, socket) do
    socket.assigns.runner |> Jobs.finish_job(job_id, payload) |> reply_to(socket)
  end

  def handle_in("job:telemetry", %{"job_id" => job_id, "records" => records}, socket)
      when is_list(records) do
    socket.assigns.runner |> Jobs.record_telemetry(job_id, records) |> reply_to(socket)
  end

  def handle_in("job:telemetry", _payload, socket),
    do: {:reply, {:error, %{"reason" => "invalid"}}, socket}

  def handle_in("runner:directories", %{"directories" => directories}, socket) do
    case Runners.update_directories(socket.assigns.runner, directories) do
      {:ok, runner} ->
        RunnerStatus.notify_changed(runner.workspace_id)
        {:reply, :ok, assign(socket, runner: runner)}

      {:error, _reason} ->
        {:reply, {:error, %{"reason" => "invalid"}}, socket}
    end
  end

  def handle_in("worktree:removed", %{"task_id" => task_id} = payload, socket) do
    socket.assigns.runner
    |> Tasks.worktree_removed(task_id, payload["error"])
    |> reply_to(socket)
  end

  def handle_in("worktree:usage", usage, socket) do
    case Runners.update_worktree_usage(socket.assigns.runner, usage) do
      {:ok, runner} ->
        RunnerStatus.notify_changed(runner.workspace_id)
        {:reply, :ok, assign(socket, runner: runner)}

      {:error, _reason} ->
        {:reply, {:error, %{"reason" => "invalid"}}, socket}
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{"reason" => "unknown_message"}}, socket}

  defp reply_to({:ok, _result}, socket), do: {:reply, :ok, socket}

  defp reply_to({:error, %Ecto.Changeset{}}, socket),
    do: {:reply, {:error, %{"reason" => "invalid"}}, socket}

  defp reply_to({:error, reason}, socket),
    do: {:reply, {:error, %{"reason" => Atom.to_string(reason)}}, socket}

  # The workspace's secrets join the job only on its way to the runner, and
  # never a proposal's: it reads untrusted text (an issue's body) with every
  # permission, and needs no secret to study a project.
  # So does the git credential of a task from a linked repository, to a
  # runner that knows it (ADR 0037).
  defp push_assign(socket, job) do
    env = if proposal?(job), do: %{}, else: Secrets.env(job.workspace_id)
    credential = git_credential(socket.assigns.runner, job)

    {:ok, wire} =
      job.context
      |> Map.merge(%{"id" => job.id, "prompt" => job.prompt})
      |> then(&if(env == %{}, do: &1, else: Map.put(&1, "env", env)))
      |> then(&if(credential, do: Map.put(&1, "git_credential", credential), else: &1))
      |> Job.new()

    push(socket, Job.assign_event(), Job.to_map(wire))
    if credential, do: schedule_renewal(job.id, credential)
  end

  defp git_credential(runner, job) do
    if not proposal?(job) and Runners.capable?(runner, "git_credential"),
      do: Integrations.git_credential_for_job(job)
  end

  # Five minutes before it expires, at least a minute from now.
  defp schedule_renewal(job_id, %{"expires_at" => expires_at}) when is_binary(expires_at) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(expires_at) do
      ms = max(DateTime.diff(at, DateTime.utc_now(), :millisecond) - renewal_margin(), 60_000)
      Process.send_after(self(), {:renew_credential, job_id}, ms)
    end
  end

  defp schedule_renewal(_job_id, _credential), do: nil

  defp renewal_margin,
    do: Application.get_env(:pipe_maestro_web, __MODULE__, [])[:renewal_margin_ms] || 300_000

  defp proposal?(job), do: is_map(job.context) and Map.has_key?(job.context, "proposal")

  # Phoenix calls terminate after a refused join too; only a runner that was
  # actually online has a "last seen" to record.
  @impl true
  def terminate(reason, %{assigns: %{joined: true, runner: runner, session_id: session_id}}) do
    Runners.touch_last_seen(runner)
    RunnerTelemetry.close_session(session_id, end_reason(runner, reason))
  end

  def terminate(_reason, _socket), do: :ok

  # A revoked runner's connection is closed by the control plane itself.
  defp end_reason(runner, reason) do
    cond do
      Runners.revoked?(runner.id) -> "revoked"
      match?({:shutdown, _}, reason) or reason == :normal -> "closed"
      true -> "crashed"
    end
  end
end
