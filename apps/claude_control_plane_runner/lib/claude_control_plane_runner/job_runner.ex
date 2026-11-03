defmodule ClaudeControlPlaneRunner.JobRunner do
  @moduledoc """
  Runs the jobs the control plane hands this runner, one at a time, in the
  runner's working directory: they share it, so two at once would step on each
  other. Jobs that arrive meanwhile wait in order.

  Each job is the agent CLI (`ClaudeControlPlaneRunner.Claude`) in a port. Its
  `stream-json` lines become `ClaudeControlPlaneProtocol.JobEvent`s, and every
  message for the control plane goes to the owner (the connection) as
  `{:job_out, event_name, payload}`, in the wire form of
  `ClaudeControlPlaneProtocol.Job`.

  Canceling a waiting job drops it; canceling the running one sends the CLI
  SIGTERM, then SIGKILL if it is still there after `:kill_after` ms.
  """
  use GenServer

  alias ClaudeControlPlaneProtocol.{Job, JobEvent}
  alias ClaudeControlPlaneRunner.Claude

  @line_bytes 1_048_576
  @stderr_tail 20

  # The CLI reads piped stdin as extra prompt; the shell gives it /dev/null
  # instead of the port's pipe, and `exec` keeps the CLI as the port's process.
  @launcher ~S(exec "$0" "$@" < /dev/null)

  @doc """
  Starts the runner. Options: `:owner` (pid, required), `:workdir` (required),
  `:executable` (default: `Claude.executable/0`), `:kill_after` (default 5000).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Queues a job. A job already queued or running is ignored."
  @spec enqueue(GenServer.server(), Job.t()) :: :ok
  def enqueue(server, %Job{} = job), do: GenServer.cast(server, {:enqueue, job})

  @doc "Drops a waiting job or stops the running one."
  @spec cancel(GenServer.server(), String.t()) :: :ok
  def cancel(server, job_id), do: GenServer.cast(server, {:cancel, job_id})

  @doc "The jobs this runner is executing right now."
  @spec running_job_ids(GenServer.server()) :: [String.t()]
  def running_job_ids(server), do: GenServer.call(server, :running_job_ids)

  @impl true
  def init(opts) do
    workdir = Keyword.fetch!(opts, :workdir)
    File.mkdir_p!(workdir)

    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       workdir: workdir,
       executable: Keyword.get_lazy(opts, :executable, &Claude.executable/0),
       kill_after: Keyword.get(opts, :kill_after, 5_000),
       queue: :queue.new(),
       current: nil
     }}
  end

  @impl true
  def handle_call(:running_job_ids, _from, state) do
    {:reply, if(state.current, do: [state.current.job.id], else: []), state}
  end

  @impl true
  def handle_cast({:enqueue, %Job{id: id} = job}, state) do
    if known?(state, id),
      do: {:noreply, state},
      else: {:noreply, maybe_start(%{state | queue: :queue.in(job, state.queue)})}
  end

  def handle_cast({:cancel, id}, %{current: %{job: %Job{id: id}} = current} = state) do
    signal_group(current.os_pid, "TERM")
    Process.send_after(self(), {:force_kill, id}, state.kill_after)
    {:noreply, %{state | current: %{current | canceled: true}}}
  end

  def handle_cast({:cancel, id}, state) do
    {:noreply, %{state | queue: :queue.filter(&(&1.id != id), state.queue)}}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, part}}}, %{current: %{port: port} = current} = state) do
    {:noreply, %{state | current: %{current | partial: current.partial <> part}}}
  end

  def handle_info({port, {:data, {:eol, part}}}, %{current: %{port: port} = current} = state) do
    line = current.partial <> part
    {:noreply, %{state | current: handle_line(state, %{current | partial: ""}, line)}}
  end

  def handle_info({port, {:exit_status, code}}, %{current: %{port: port} = current} = state) do
    finish(state, current, code)
    {:noreply, maybe_start(%{state | current: nil})}
  end

  def handle_info({:force_kill, id}, %{current: %{job: %Job{id: id}} = current} = state) do
    signal_group(current.os_pid, "KILL")
    {:noreply, state}
  end

  # The job ended before the deadline.
  def handle_info({:force_kill, _id}, state), do: {:noreply, state}

  defp known?(state, id) do
    (state.current && state.current.job.id == id) ||
      Enum.any?(:queue.to_list(state.queue), &(&1.id == id))
  end

  defp maybe_start(%{current: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, job}, queue} -> start(%{state | queue: queue}, job)
      {:empty, _queue} -> state
    end
  end

  defp maybe_start(state), do: state

  defp start(state, job) do
    out(state, Job.started_event(), %{"job_id" => job.id})

    case state.executable do
      {:ok, path} ->
        port =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, @line_bytes},
            {:cd, state.workdir},
            {:env, Claude.env()},
            {:args, ["-c", @launcher, path | Claude.argv(job.prompt)]}
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)

        %{
          state
          | current: %{
              job: job,
              port: port,
              os_pid: os_pid,
              seq: 0,
              partial: "",
              result: nil,
              stderr: [],
              canceled: false
            }
        }

      {:error, :not_found} ->
        out(state, Job.finished_event(), %{
          "job_id" => job.id,
          "status" => "failed",
          "error" =>
            "O CLI do claude não foi encontrado no PATH deste runner (ou em $CLAUDE_BIN)."
        })

        maybe_start(state)
    end
  end

  defp handle_line(state, current, line) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) ->
        decoded
        |> JobEvent.from_stream_json()
        |> Enum.reduce(current, &report_event(state, &2, &1))

      _not_json ->
        %{current | stderr: Enum.take([line | current.stderr], @stderr_tail)}
    end
  end

  defp report_event(state, current, %JobEvent{} = event) do
    seq = current.seq + 1

    payload =
      event
      |> JobEvent.to_map()
      |> Map.merge(%{"job_id" => current.job.id, "seq" => seq})

    out(state, Job.event_event(), payload)
    result = if event.type == "result", do: event.data, else: current.result
    %{current | seq: seq, result: result}
  end

  defp finish(state, current, exit_code) do
    result = current.result || %{}

    status =
      cond do
        current.canceled -> "canceled"
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
      "num_turns" => result["num_turns"]
    }

    out(state, Job.finished_event(), maybe_error(payload, status, exit_code, current))
  end

  defp maybe_error(payload, "failed", exit_code, current) do
    tail = current.stderr |> Enum.reverse() |> Enum.join("\n")
    Map.put(payload, "error", String.trim("O claude terminou com código #{exit_code}.\n#{tail}"))
  end

  defp maybe_error(payload, _status, _exit_code, _current), do: payload

  # The port's process leads its own session and process group, and everything
  # the CLI starts (the shell commands of the agent's tools) joins that group.
  # Signaling the group reaches them all, even a child orphaned by the CLI's
  # exit, which would otherwise hold the port's pipe open and the job with it.
  defp signal_group(os_pid, signal) do
    System.cmd("kill", ["-s", signal, "--", "-#{os_pid}"], stderr_to_stdout: true)
  end

  defp out(state, event, payload), do: send(state.owner, {:job_out, event, payload})
end
