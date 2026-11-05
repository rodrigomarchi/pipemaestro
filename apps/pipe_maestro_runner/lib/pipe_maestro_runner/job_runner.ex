defmodule PipeMaestroRunner.JobRunner do
  @moduledoc """
  Runs the jobs the control plane hands this runner, up to `:capacity` at a
  time. Jobs that share a place to run wait for each other, in order:

    * the stages of one task share its worktree, except the stages of a
      group (`parallel`), which run at once;
    * jobs in a directory without a worktree share that directory;
    * jobs on their own share the runner's workdir.

  Jobs in different places (two tasks, each in its own worktree) run at once.

  Before the agent starts, the job's place is prepared off this process (a
  worktree may take a while to create and set up,
  `PipeMaestroRunner.Setup`), so the other jobs' output keeps flowing.
  A worktree whose setup fails is removed, so the next try starts it over.

  Each job is the agent CLI (`PipeMaestroRunner.Claude`) in a port. Its
  `stream-json` lines become `PipeMaestroProtocol.JobEvent`s, and every
  message for the control plane goes to the owner (the connection) as
  `{:job_out, event_name, payload}`, in the wire form of
  `PipeMaestroProtocol.Job`. What the agent is writing goes as
  `{:job_live, "job:delta", payload}`, at most every 250 ms: it is not
  kept if it cannot be delivered.

  With `telemetry: true`, the runner receives the CLI's OpenTelemetry on this
  machine (`PipeMaestroRunner.Telemetry.Receiver`) and relays each
  job's records as `{:job_out, "job:telemetry", %{"job_id", "records"}}`, in
  batches; they may follow the job's outcome.

  The outcome (`job:finished`) carries, besides the result, what the run
  reported about itself for auditing: the session, the CLI's version, the
  model, the tokens with the cache apart, the cost per model, the denied
  permissions, what the agent had at hand (tools, MCP servers, agents...),
  how long the agent's process ran (`wall_ms`) and the end of its stderr.
  Each message's tokens go once: a message split over several lines keeps
  them on its first event.

  Canceling a waiting job drops it; canceling a running one (in its setup or
  in the CLI) sends SIGTERM, then SIGKILL if it is still there after
  `:kill_after` ms. A job past its `timeout_ms` is stopped the same way and
  fails.
  """
  use GenServer

  alias PipeMaestroProtocol.{Job, JobEvent, Telemetry, Text, Worktree}

  alias PipeMaestroRunner.{
    Changes,
    Checks,
    Claude,
    Delivery,
    Gates,
    RepoState,
    Setup,
    Shell,
    Workspace
  }

  alias PipeMaestroRunner.Telemetry.Receiver

  @line_bytes 1_048_576
  @artifact_bytes 65_536
  @stderr_tail 200
  @stderr_bytes 16_000
  @delta_every_ms 250
  @delta_bytes 4_000

  # The CLI reads piped stdin as extra prompt; the shell gives it /dev/null
  # instead of the port's pipe, and `exec` keeps the CLI as the port's process.
  @launcher ~S(exec "$0" "$@" < /dev/null)

  @doc """
  Starts the runner. Options: `:owner` (pid, required), `:workdir` (required),
  `:root` (where the code directories are, `PipeMaestroRunner.Workspace`),
  `:executable` (default: `Claude.executable/0`), `:kill_after` (default 5000),
  `:capacity` (jobs at once, default 1), `:telemetry` (receive the CLI's
  OpenTelemetry, default false).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Queues a job. A job already queued or running is ignored."
  @spec enqueue(GenServer.server(), Job.t()) :: :ok
  def enqueue(server, %Job{} = job), do: GenServer.cast(server, {:enqueue, job})

  @doc "Drops a waiting job or stops the running one."
  @spec cancel(GenServer.server(), String.t()) :: :ok
  def cancel(server, job_id), do: GenServer.cast(server, {:cancel, job_id})

  @doc """
  Removes a task's worktree (`PipeMaestroRunner.Workspace`), unless a
  job of the task is running or waiting. Reports to the owner as
  `{:job_out, "worktree:removed", %{"task_id" => id}}`, with `"error"` when it
  could not.
  """
  @spec remove_worktree(GenServer.server(), String.t(), String.t()) :: :ok
  def remove_worktree(server, task_id, directory),
    do: GenServer.cast(server, {:remove_worktree, task_id, directory})

  @doc "The jobs this runner is executing right now."
  @spec running_job_ids(GenServer.server()) :: [String.t()]
  def running_job_ids(server), do: GenServer.call(server, :running_job_ids)

  @impl true
  def init(opts) do
    workdir = Keyword.fetch!(opts, :workdir)
    File.mkdir_p!(workdir)
    :ok = Workspace.clear_scratch(workdir)

    endpoint =
      if Keyword.get(opts, :telemetry, false) do
        {:ok, receiver} = Receiver.start_link(target: self())
        Receiver.endpoint(receiver)
      end

    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       workdir: workdir,
       root: Keyword.get(opts, :root),
       executable: Keyword.get_lazy(opts, :executable, &Claude.executable/0),
       kill_after: Keyword.get(opts, :kill_after, 5_000),
       capacity: Keyword.get(opts, :capacity) || 1,
       telemetry_endpoint: endpoint,
       queue: [],
       running: %{}
     }}
  end

  @impl true
  def handle_call(:running_job_ids, _from, state) do
    {:reply, Map.keys(state.running), state}
  end

  @impl true
  def handle_cast({:enqueue, %Job{id: id} = job}, state) do
    if known?(state, id),
      do: {:noreply, state},
      else: {:noreply, start_ready(%{state | queue: state.queue ++ [job]})}
  end

  def handle_cast({:remove_worktree, task_id, directory}, state) do
    if task_in_use?(state, task_id) do
      out(state, Worktree.removed_event(), %{
        "task_id" => task_id,
        "error" => "A tarefa tem uma etapa em execução neste runner."
      })
    else
      remove_in_background(state, task_id, directory)
    end

    {:noreply, state}
  end

  def handle_cast({:cancel, id}, state) do
    case state.running do
      %{^id => run} ->
        {:noreply, put_run(state, stop(state, %{run | canceled: true}))}

      _waiting ->
        {:noreply, %{state | queue: Enum.reject(state.queue, &(&1.id == id))}}
    end
  end

  @impl true
  def handle_info({port, {:data, {:noeol, part}}}, state) when is_port(port) do
    with_run(state, port, fn run -> %{run | partial: run.partial <> part} end)
  end

  def handle_info({port, {:data, {:eol, part}}}, state) when is_port(port) do
    with_run(state, port, fn run ->
      handle_line(state, %{run | partial: ""}, run.partial <> part)
    end)
  end

  def handle_info({port, {:exit_status, code}}, state) when is_port(port) do
    case run_for(state, port) do
      nil -> {:noreply, state}
      run -> {:noreply, after_exit(state, run, code)}
    end
  end

  # Records may name a job that has already ended: they still go out.
  def handle_info({:telemetry, records}, state) do
    for {job_id, of_job} <- Enum.group_by(records, &elem(&1, 0), &elem(&1, 1)),
        batch <- Enum.chunk_every(of_job, Telemetry.max_records()) do
      out(state, Telemetry.event(), %{"job_id" => job_id, "records" => batch})
    end

    {:noreply, state}
  end

  def handle_info({:force_kill, id}, state) do
    # The job may have ended before the deadline.
    with %{^id => %{os_pid: os_pid}} when is_integer(os_pid) <- state.running,
         do: signal_group(os_pid, "KILL")

    {:noreply, state}
  end

  def handle_info({:timeout, id, port}, state) do
    case state.running do
      %{^id => %{port: ^port} = run} ->
        {:noreply, put_run(state, stop(state, %{run | timed_out: true}))}

      _ended ->
        {:noreply, state}
    end
  end

  # A setup or gate command started: it can now be stopped, or must be at once.
  def handle_info({:child_os_pid, id, os_pid}, state) do
    case state.running do
      %{^id => run} ->
        run = %{run | os_pid: os_pid}
        {:noreply, put_run(state, if(run.canceled, do: stop(state, run), else: run))}

      _ended ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Enum.find(Map.values(state.running), &(&1.preparing == ref or task_ref(&1) == ref)) do
      nil ->
        {:noreply, state}

      %{preparing: ^ref} = run ->
        {:noreply, launch(state, %{run | preparing: nil, os_pid: nil}, result)}

      %{finishing: {^ref, code}} = run ->
        {:noreply, finish(state, run, code, result)}
    end
  end

  # What follows the agent's exit: the job ends now, or once the checks, the
  # gates, the delivery and the changes are measured.
  defp after_exit(state, run, code) do
    run = %{run | wall_ms: wall_ms(run)}
    {checks, gates, delivery} = after_steps(run, code)

    if run.tracking == nil and gates == [] and checks == [] and delivery == nil,
      do: finish(state, run, code, %{}),
      else: put_run(state, after_agent(run, code, {checks, gates}, delivery))
  end

  # The gates follow an agent that ended well; the checks and the delivery,
  # one that also did not block.
  defp after_steps(run, code) do
    cond do
      not agent_succeeded?(run, code) -> {[], [], nil}
      not stage_ok?(run) -> {[], run.job.gates || [], nil}
      true -> {run.job.checks || [], run.job.gates || [], run.job.delivery}
    end
  end

  # Of the job's secrets, only the one the delivery signs in to a Forgejo
  # with, when git has no credential for it.
  defp delivery_env(job) do
    for {"FORGEJO_TOKEN" = name, value} <- job.env || %{}, do: {name, value}
  end

  # After the agent, off this process (they take a while): the platform's
  # checks, the gates, the delivery when all passed, then what the stage
  # changed.
  defp after_agent(run, code, steps, delivery) do
    runner = self()
    %{dir: dir, tracking: tracking, job: job} = run

    task =
      Task.async(fn ->
        on_os_pid = &send(runner, {:child_os_pid, job.id, &1})
        results = verify(dir, job, tracking, steps, on_os_pid)

        delivered =
          if delivery && Enum.all?(results || [], & &1["passed"]),
            do: Delivery.deliver(dir, delivery, env: delivery_env(job))

        changes = if tracking, do: Changes.report(dir, tracking)
        %{"gates" => results, "changes" => changes, "delivery" => delivered}
      end)

    %{run | port: nil, os_pid: nil, finishing: {task.ref, code}}
  end

  # The checks, then the gates when the checks hold (a gate run on a worktree
  # the checks refused would be time spent for nothing); `nil` when there were
  # none.
  defp verify(dir, job, tracking, {checks, gates}, on_os_pid) do
    exclude = (tracking && tracking[:exclude]) || []
    checked = Checks.run(dir, checks, env: Map.to_list(job.env || %{}), exclude: exclude)

    gated =
      if gates == [] or not Enum.all?(checked, & &1["passed"]),
        do: [],
        else: Gates.run(dir, gates, on_os_pid)

    if checked ++ gated == [], do: nil, else: checked ++ gated
  end

  # A stage the agent did not block (when it was asked for structured output).
  defp stage_ok?(%{result: %{"structured_output" => %{"status" => status}}}), do: status == "ok"
  defp stage_ok?(_run), do: true

  defp agent_succeeded?(run, code),
    do:
      code == 0 and not run.canceled and not run.timed_out and
        (run.result || %{})["is_error"] != true

  defp task_ref(%{finishing: {ref, _code}}), do: ref
  defp task_ref(_run), do: nil

  defp with_run(state, port, fun) do
    case run_for(state, port) do
      nil -> {:noreply, state}
      run -> {:noreply, put_run(state, fun.(run))}
    end
  end

  defp run_for(state, port),
    do: Enum.find_value(state.running, fn {_id, r} -> r.port == port && r end)

  defp put_run(state, run), do: %{state | running: Map.put(state.running, run.job.id, run)}

  defp task_in_use?(state, task_id) do
    of_task? = &match?(%Job{worktree: %{"task_id" => ^task_id}}, &1)
    Enum.any?(Map.values(state.running), &of_task?.(&1.job)) or Enum.any?(state.queue, of_task?)
  end

  # Removing a large worktree takes a while; the reply goes straight out.
  defp remove_in_background(state, task_id, directory) do
    %{owner: owner, root: root, workdir: workdir} = state

    Task.start(fn ->
      reply =
        case Workspace.remove_task_worktree(root, workdir, task_id, directory) do
          :ok -> %{"task_id" => task_id}
          {:error, message} -> %{"task_id" => task_id, "error" => message}
        end

      send(owner, {:job_out, Worktree.removed_event(), reply})
    end)
  end

  defp known?(state, id),
    do: Map.has_key?(state.running, id) or Enum.any?(state.queue, &(&1.id == id))

  # Where a job runs, as far as waiting goes: jobs with the same place never run
  # at once.
  defp place(%Job{directory: nil}), do: :workdir
  # An analysis has a worktree of its own: it waits for nothing.
  defp place(%Job{scratch: true, id: id}), do: {:scratch, id}
  # Stages of a group run at once in their task's worktree.
  defp place(%Job{worktree: %{"task_id" => task_id}, parallel: true, id: id}),
    do: {:task, task_id, id}

  defp place(%Job{worktree: %{"task_id" => task_id}}), do: {:task, task_id}
  defp place(%Job{directory: directory}), do: {:directory, directory}

  # Starts, in queue order, every waiting job whose place is free, while there
  # is capacity.
  defp start_ready(state) do
    busy = MapSet.new(Map.values(state.running), &place(&1.job))

    with true <- map_size(state.running) < state.capacity,
         %Job{} = job <- Enum.find(state.queue, &(not MapSet.member?(busy, place(&1)))) do
      state
      |> Map.update!(:queue, &List.delete(&1, job))
      |> start(job)
      |> start_ready()
    else
      _full_or_nothing_ready -> state
    end
  end

  defp start(state, job) do
    out(state, Job.started_event(), %{"job_id" => job.id})
    runner = self()
    %{root: root, workdir: workdir, executable: executable} = state

    task =
      Task.async(fn ->
        on_os_pid = &send(runner, {:child_os_pid, job.id, &1})
        prepare(job, executable, root, workdir, on_os_pid)
      end)

    put_run(state, %{
      job: job,
      preparing: task.ref,
      dir: nil,
      setup: nil,
      port: nil,
      os_pid: nil,
      seq: 0,
      partial: "",
      result: nil,
      stderr: [],
      canceled: false,
      timed_out: false,
      tracking: nil,
      finishing: nil,
      typing: "",
      typed_at: nil,
      session: nil,
      messages: MapSet.new(),
      launched_at: nil,
      wall_ms: nil
    })
  end

  # Runs in a task: the working directory, set up when it is a new worktree.
  defp prepare(job, executable, root, workdir, on_os_pid) do
    with {:ok, path} <- executable(executable),
         {:ok, dir, source} <- Workspace.prepare(job, root, workdir) do
      setup = if source, do: Setup.run(source, dir, job.setup, on_os_pid: on_os_pid)

      if setup_failed?(setup) do
        _removed = Workspace.remove_worktree(source, dir)
        message = "O setup do worktree falhou (código #{setup["exit_code"]}).\n#{setup["output"]}"
        {:error, String.trim(message), setup}
      else
        notes = before_agent(job, dir)
        {:ok, path, dir, setup, track(job, workdir, dir, setup), notes}
      end
    else
      {:error, message} -> {:error, message, nil}
    end
  end

  # A task's stage: the earlier artifacts missing on disk are written back
  # (from the control plane), then the worktree is synced with origin. What
  # the agent should know about it goes at the end of its prompt.
  defp before_agent(%Job{worktree: %{"branch" => branch}} = job, dir) do
    for %{"path" => path, "content" => content} <- job.artifacts || [],
        file = Path.join(dir, path),
        not File.exists?(file) do
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end

    if job.sync, do: RepoState.sync(dir, branch)
  end

  defp before_agent(_job, _dir), do: nil

  # A task's worktree is compared before and after each stage.
  # What the setup put in a new worktree (the paths it copied and what its
  # command created outside git) is the platform's, not the task's: it stays
  # out of the snapshots and of the "clean" check.
  defp track(%Job{worktree: %{"task_id" => task_id}}, workdir, dir, setup) do
    exclude = if setup, do: Enum.uniq((setup["copied"] || []) ++ Changes.untracked(dir)), else: []
    Changes.start(workdir, task_id, dir, setup != nil, exclude)
  end

  # An analysis's worktree is thrown away: what it changed there does not matter.
  defp track(%Job{scratch: true}, _workdir, _dir, _setup), do: nil

  # A directory without git: which files the stage created, changed or removed.
  defp track(%Job{directory: directory}, _workdir, dir, _setup) when is_binary(directory),
    do: %{files: Changes.file_snapshot(dir), exclude: []}

  defp track(_job, _workdir, _dir, _setup), do: nil

  defp setup_failed?(%{"exit_code" => code}) when code != 0, do: true
  defp setup_failed?(_setup), do: false

  defp launch(state, %{canceled: true} = run, prepared) do
    done(state, run, %{"status" => "canceled", "setup" => setup_of(prepared)})
  end

  defp launch(state, run, {:error, message, setup}) do
    done(state, run, %{"status" => "failed", "error" => message, "setup" => setup})
  end

  defp launch(state, run, {:ok, path, dir, setup, tracking, notes}) do
    job = if notes, do: %{run.job | prompt: run.job.prompt <> "\n\n" <> notes}, else: run.job

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, @line_bytes},
        {:cd, dir},
        {:env, Claude.env(job, state.telemetry_endpoint)},
        {:args, ["-c", @launcher, path | Claude.argv(job)]}
      ])

    # A CLI that ends at once has no process left to stop.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    if job.timeout_ms, do: Process.send_after(self(), {:timeout, job.id, port}, job.timeout_ms)

    put_run(state, %{
      run
      | job: job,
        dir: dir,
        setup: setup,
        tracking: tracking,
        port: port,
        os_pid: os_pid,
        launched_at: System.monotonic_time(:millisecond)
    })
  end

  defp wall_ms(%{launched_at: nil}), do: nil
  defp wall_ms(%{launched_at: at}), do: System.monotonic_time(:millisecond) - at

  defp setup_of({:ok, _path, _dir, setup, _tracking, _notes}), do: setup
  defp setup_of({:error, _message, setup}), do: setup

  # A job that ended before its agent ran.
  defp done(state, run, payload) do
    payload =
      for {key, value} <- payload, value != nil, into: %{"job_id" => run.job.id}, do: {key, value}

    out(state, Job.finished_event(), payload)
    discard_scratch(state, run.job)
    start_ready(%{state | running: Map.delete(state.running, run.job.id)})
  end

  # Stops what the job is running now (the setup command or the CLI); a job
  # still creating its worktree stops once that is done.
  defp stop(state, %{os_pid: os_pid, job: job} = run) when is_integer(os_pid) do
    signal_group(os_pid, "TERM")
    Process.send_after(self(), {:force_kill, job.id}, state.kill_after)
    run
  end

  defp stop(_state, run), do: run

  defp executable({:ok, path}), do: {:ok, path}

  defp executable(_not_found),
    do: {:error, "O CLI do claude não foi encontrado no PATH deste runner (ou em $CLAUDE_BIN)."}

  defp handle_line(state, current, line) do
    case JSON.decode(line) do
      {:ok, decoded} when is_map(decoded) ->
        case JobEvent.text_delta(decoded) do
          nil ->
            decoded
            |> JobEvent.from_stream_json()
            |> Enum.reduce(%{current | typing: ""}, &report_event(state, &2, &1))

          text ->
            typed(state, current, text)
        end

      _not_json ->
        %{current | stderr: Enum.take([line | current.stderr], @stderr_tail)}
    end
  end

  # What the agent is writing, relayed at most every @delta_every_ms (the
  # first part at once): the text so far, its end if it is long.
  defp typed(state, current, text) do
    typing = current.typing <> text
    now = System.monotonic_time(:millisecond)

    if current.typed_at == nil or now - current.typed_at >= @delta_every_ms do
      send(
        state.owner,
        {:job_live, Job.delta_event(),
         %{"job_id" => current.job.id, "text" => Text.tail(typing, @delta_bytes)}}
      )

      %{current | typing: typing, typed_at: now}
    else
      %{current | typing: typing}
    end
  end

  defp report_event(state, current, %JobEvent{} = event) do
    {event, current} = count_usage_once(event, current)
    seq = current.seq + 1

    payload =
      event
      |> JobEvent.to_map()
      |> Map.merge(%{"job_id" => current.job.id, "seq" => seq})

    out(state, Job.event_event(), payload)
    result = if event.type == "result", do: event.data, else: current.result
    session = if event.type == "system", do: event.data, else: current.session
    %{current | seq: seq, result: result, session: session}
  end

  # A message split over several lines repeats its tokens on each: only the
  # first of its events keeps them.
  defp count_usage_once(%JobEvent{data: %{"usage" => %{"message_id" => id}}} = event, current)
       when is_binary(id) do
    if MapSet.member?(current.messages, id),
      do: {%{event | data: Map.delete(event.data, "usage")}, current},
      else: {event, %{current | messages: MapSet.put(current.messages, id)}}
  end

  defp count_usage_once(event, current), do: {event, current}

  # Reports how the job ended (with what was measured after the agent) and
  # frees its place.
  defp finish(state, current, exit_code, measured) do
    result = current.result || %{}

    status =
      cond do
        current.canceled -> "canceled"
        current.timed_out -> "failed"
        exit_code == 0 and result["is_error"] != true -> "succeeded"
        true -> "failed"
      end

    payload = %{
      "job_id" => current.job.id,
      "status" => status,
      "exit_code" => exit_code,
      "result" => result["text"],
      "cost_usd" => result["cost_usd"],
      "duration_ms" => result["duration_ms"],
      "num_turns" => result["num_turns"],
      "structured_output" => result["structured_output"],
      "artifact" => read_artifact(current),
      "workdir" => current.dir
    }

    payload = Map.merge(payload, audit(current, result))

    payload =
      for {key, value} <- Map.put(measured, "setup", current.setup),
          value != nil,
          into: payload,
          do: {key, value}

    out(state, Job.finished_event(), maybe_error(payload, status, exit_code, current))
    discard_scratch(state, current.job)
    start_ready(%{state | running: Map.delete(state.running, current.job.id)})
  end

  # An analysis's worktree goes once its job reported (its artifact read), in
  # the background: deleting copied dependencies can take a while.
  defp discard_scratch(state, %Job{scratch: true} = job) do
    %{root: root, workdir: workdir} = state
    {:ok, _pid} = Task.start(fn -> Workspace.remove_scratch(job, root, workdir) end)
    :ok
  end

  defp discard_scratch(_state, _job), do: :ok

  # What the run reported about itself, from its first and last lines and the
  # runner's own measures.
  defp audit(current, result) do
    session = current.session || %{}

    environment =
      session
      |> Map.take(~w(tools mcp_servers agents skills slash_commands plugins
                     permission_mode auth output_style))
      |> Map.reject(fn {_key, value} -> value in [nil, []] end)

    %{
      "session_id" => result["session_id"] || session["session_id"],
      "cli_version" => session["version"],
      "model" => session["model"],
      "stop_reason" => result["stop_reason"],
      "result_subtype" => result["subtype"],
      "duration_api_ms" => result["duration_api_ms"],
      "ttft_ms" => result["ttft_ms"],
      "wall_ms" => current.wall_ms,
      "usage" => result["usage"],
      "model_usage" => result["model_usage"],
      "permission_denials" => result["permission_denials"],
      "subagents" => result["subagents"],
      "environment" => if(environment == %{}, do: nil, else: environment),
      "stderr" => stderr(current)
    }
  end

  defp stderr(%{stderr: []}), do: nil

  defp stderr(%{stderr: lines}) do
    lines |> Enum.reverse() |> Enum.join("\n") |> Text.tail(@stderr_bytes)
  end

  defp read_artifact(%{job: %Job{artifact_path: nil}}), do: nil

  defp read_artifact(%{job: %Job{artifact_path: path}, dir: dir}) do
    case File.open(Path.join(dir, path), [:read, :binary], &IO.binread(&1, @artifact_bytes)) do
      {:ok, data} when is_binary(data) -> Text.valid_utf8(data)
      _missing -> nil
    end
  end

  defp maybe_error(payload, "failed", _exit_code, %{timed_out: true, job: job}) do
    minutes = Float.round(job.timeout_ms / 60_000, 1)
    Map.put(payload, "error", "O tempo máximo da etapa (#{minutes} min) se esgotou.")
  end

  defp maybe_error(payload, "failed", exit_code, current) do
    tail = current.stderr |> Enum.take(20) |> Enum.reverse() |> Enum.join("\n")
    Map.put(payload, "error", String.trim("O claude terminou com código #{exit_code}.\n#{tail}"))
  end

  defp maybe_error(payload, _status, _exit_code, _current), do: payload

  # The port's process leads its own session and process group, and everything
  # the CLI starts (the shell commands of the agent's tools) joins that group.
  # Signaling the group reaches them all, even a child orphaned by the CLI's
  # exit, which would otherwise hold the port's pipe open and the job with it.
  defp signal_group(os_pid, signal), do: Shell.signal(os_pid, signal)

  defp out(state, event, payload), do: send(state.owner, {:job_out, event, payload})
end
