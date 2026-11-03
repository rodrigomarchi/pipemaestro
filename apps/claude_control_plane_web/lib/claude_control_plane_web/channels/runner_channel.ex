defmodule ClaudeControlPlaneWeb.RunnerChannel do
  @moduledoc """
  One runner's channel (`runner:<id>`). Joining announces the runner
  (`ClaudeControlPlaneProtocol.Hello`): the details are stored and the runner
  is tracked as online in its workspace until the channel ends.

  Jobs travel on it too (`ClaudeControlPlaneProtocol.Job`): the channel pushes
  `job:assign` and `job:cancel` as the runner's jobs are created and canceled,
  hands over the queued ones again on every join, and stores what the runner
  reports (`job:started`, `job:event`, `job:finished`).
  """
  use Phoenix.Channel

  alias ClaudeControlPlane.{Jobs, Runners}
  alias ClaudeControlPlaneProtocol.{Hello, Job}
  alias ClaudeControlPlaneWeb.RunnerStatus

  @impl true
  def join("runner:" <> runner_id, payload, socket) do
    runner = socket.assigns.runner

    with true <- runner_id == runner.id,
         {:ok, hello} <- Hello.from_map(payload) do
      {:ok, runner} = Runners.record_hello(runner, hello)
      send(self(), {:after_join, hello})

      {:ok,
       %{"runner_id" => runner.id, "name" => runner.name, "workspace" => runner.workspace.name},
       assign(socket, runner: runner, joined: true)}
    else
      false -> {:error, %{"reason" => "unauthorized"}}
      {:error, reason} -> {:error, %{"reason" => "invalid_hello", "detail" => reason}}
    end
  end

  @impl true
  def handle_info({:after_join, hello}, socket) do
    runner = socket.assigns.runner
    {:ok, _ref} = RunnerStatus.track(self(), runner)
    RunnerStatus.notify_changed(runner.workspace_id)

    :ok = Jobs.subscribe({:runner, runner.id})
    for job <- Jobs.reconcile(runner, hello.running_job_ids), do: push_assign(socket, job)

    {:noreply, socket}
  end

  def handle_info({:job_assign, job}, socket) do
    push_assign(socket, job)
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

  def handle_in("job:event", %{"job_id" => job_id} = payload, socket) do
    socket.assigns.runner |> Jobs.append_event(job_id, payload) |> reply_to(socket)
  end

  def handle_in("job:finished", %{"job_id" => job_id} = payload, socket) do
    socket.assigns.runner |> Jobs.finish_job(job_id, payload) |> reply_to(socket)
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{"reason" => "unknown_message"}}, socket}

  defp reply_to({:ok, _result}, socket), do: {:reply, :ok, socket}

  defp reply_to({:error, %Ecto.Changeset{}}, socket),
    do: {:reply, {:error, %{"reason" => "invalid"}}, socket}

  defp reply_to({:error, reason}, socket),
    do: {:reply, {:error, %{"reason" => Atom.to_string(reason)}}, socket}

  defp push_assign(socket, job) do
    {:ok, wire} = Job.new(%{id: job.id, prompt: job.prompt})
    push(socket, Job.assign_event(), Job.to_map(wire))
  end

  # Phoenix calls terminate after a refused join too; only a runner that was
  # actually online has a "last seen" to record.
  @impl true
  def terminate(_reason, %{assigns: %{joined: true, runner: runner}}) do
    Runners.touch_last_seen(runner)
    :ok
  end

  def terminate(_reason, _socket), do: :ok
end
