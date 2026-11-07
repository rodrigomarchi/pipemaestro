defmodule PipeMaestroRunner.Connection do
  @moduledoc """
  The runner's connection to the control plane: an outbound WebSocket that
  authenticates with the runner's token, joins `runner:<id>` announcing this
  machine, and reconnects with backoff when the network drops.

  When the platform refuses the connection itself (HTTP 403: the token was
  revoked or the protocol version is no longer accepted) reconnecting cannot
  help, so the connection stops and reports `:rejected`. When it refuses the
  join because this runner is not on the platform's version (`"outdated"`),
  it drains before the update, without connecting again: it starts no more
  jobs, lets the running ones end (up to `:drain_timeout_ms`, default 30
  minutes; past it they are stopped as lost, `JobRunner.cancel/3`), writes
  the whole outbox to its file, and only then reports `{:outdated, refusal}`
  and stops.

  Given a `:workdir`, it also runs jobs through a
  `PipeMaestroRunner.JobRunner` (its own, with the capacity announced in
  the hello, or the `:job_runner` it is given), hands it the `job:assign` and
  `job:cancel` messages, pushes back what it reports, and tells the control
  plane which jobs survive a reconnection (`Hello.running_job_ids`).

  What it reports is kept until the control plane replies (a
  `PipeMaestroRunner.Outbox.Server`: its own, or the `:outbox` it is given,
  which outlives it) and sent again, in order, after every join; a job whose
  end the control plane has not confirmed still counts as running, so a
  reconnection does not fail it. With an `:outbox_path`, the ends survive a
  restart too. `PipeMaestroRunner.Session` gives it both, so a crash of the
  connection loses neither the jobs nor what they reported.

  With `telemetry: true`, the jobs' CLIs report their OpenTelemetry to the
  runner, which relays it (`job:telemetry`, `PipeMaestroProtocol.Telemetry`).

  Given a `:root`, it offers the code directories under it
  (`PipeMaestroRunner.Directories`): announced on every join and sent
  again (`runner:directories`) when they change, checked every `:rescan_every`
  ms (default one minute).

  It also looks after the task worktrees: removes one when the platform asks
  (`worktree:remove`) and reports the space they take (`worktree:usage`)
  after every join and then every `:usage_every` ms (default five minutes)
  when it changed.

  With `:health_every` (ms; `runner.start` passes
  `PipeMaestroProtocol.RunnerHealth.interval_ms/0`), it samples this
  machine's health (`PipeMaestroRunner.Health`) after every join and then
  at that interval, and sends it (`runner:health`) while joined; a sample
  taken while disconnected is dropped.

  With `:doctor_every` (ms; `runner.start` passes
  `PipeMaestroProtocol.RunnerDoctor.interval_ms/0`), it runs the runner's
  diagnosis (`PipeMaestroRunner.Doctor`) after every join, at that interval
  and when the platform asks (`runner:doctor`, answered with the request's
  id), and sends it while joined. Connected, the platform is known to
  answer, so that check is not run; `:doctor_opts` go to `Doctor.run/1`
  (for tests).

  With `logs: true`, it is the sink of the runner's log
  (`PipeMaestroRunner.LogCollector`): after every join it attaches to the
  collector, sending all the lines or, when the join's reply says the
  workspace keeps no log, only the events; the batches go through the outbox
  (`runner:log`). It also tells the log when its connection drops
  (`connection_lost`) and, at most once a minute, when the outbox dropped
  messages for lack of room (`outbox_dropped`).

  Progress is reported to `:notify` (a pid) as `{:runner_connection, event}`
  with `event` one of `{:joined, reply}`, `{:disconnected, reason}`,
  `:rejected`, `{:outdated, refusal}`, `{:job_started, job_id}` and
  `{:job_finished, payload}`.
  """
  use Slipstream, restart: :temporary

  require Logger

  alias PipeMaestroProtocol.{Hello, Job, RunnerDoctor, RunnerHealth, RunnerLog, Worktree}

  alias PipeMaestroRunner.{
    Config,
    Directories,
    Disk,
    Doctor,
    Health,
    JobRunner,
    LogCollector
  }

  alias PipeMaestroRunner.Outbox.Server, as: OutboxServer

  @default_drain_timeout_ms 1_800_000

  @doc "Starts the connection with the runner's credentials and hello."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Slipstream.start_link(__MODULE__, opts)

  @doc "The WebSocket URL for a platform URL (`http` becomes `ws`)."
  @spec websocket_url(String.t(), String.t()) :: String.t()
  def websocket_url(platform_url, token) do
    uri = URI.parse(platform_url)
    scheme = if uri.scheme == "https", do: "wss", else: "ws"

    URI.to_string(%URI{
      uri
      | scheme: scheme,
        path: PipeMaestroProtocol.socket_path() <> "/websocket",
        query: URI.encode_query(token: token, protocol_version: PipeMaestroProtocol.version())
    })
  end

  @impl Slipstream
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    %Hello{} = hello = Keyword.fetch!(opts, :hello)
    outbox = outbox_server(opts)
    :ok = OutboxServer.register(outbox, self())
    job_runner = job_runner(opts, outbox)

    # :connect_options reaches Slipstream as is (tests pass `test_mode?: true`).
    socket =
      [uri: websocket_url(config.url, config.token), reconnect_after_msec: backoff()]
      |> Keyword.merge(Keyword.get(opts, :connect_options, []))
      |> connect!()
      |> assign(
        topic: PipeMaestroProtocol.runner_topic(config.runner_id),
        hello: hello,
        notify: Keyword.get(opts, :notify),
        job_runner: job_runner,
        root: Keyword.get(opts, :root),
        rescan_every: Keyword.get(opts, :rescan_every, 60_000),
        directories: [],
        workdir: Keyword.get(opts, :workdir),
        usage_every: Keyword.get(opts, :usage_every, 300_000),
        usage: nil,
        measuring: nil,
        config: config,
        doctor_every: Keyword.get(opts, :doctor_every),
        doctor_opts: Keyword.get(opts, :doctor_opts, []),
        doctor: nil,
        doctor_request: nil,
        doctor_timer: nil,
        logs: Keyword.get(opts, :logs, false),
        drops_told: {0, nil},
        health_every: Keyword.get(opts, :health_every),
        sampling: nil,
        health_timer: nil,
        cpu: nil,
        outbox: outbox,
        drain_timeout_ms: Keyword.get(opts, :drain_timeout_ms, @default_drain_timeout_ms),
        draining: nil
      )

    schedule_rescan(socket)
    {:ok, socket}
  end

  defp schedule_rescan(%{assigns: %{root: nil}}), do: :ok

  defp schedule_rescan(%{assigns: %{rescan_every: every}}),
    do: Process.send_after(self(), :rescan, every)

  defp outbox_server(opts) do
    case Keyword.fetch(opts, :outbox) do
      {:ok, server} ->
        server

      :error ->
        {:ok, pid} = OutboxServer.start_link(path: Keyword.get(opts, :outbox_path))
        pid
    end
  end

  defp job_runner(opts, outbox) do
    case {Keyword.fetch(opts, :job_runner), Keyword.fetch(opts, :workdir)} do
      {{:ok, job_runner}, _workdir} ->
        job_runner

      {:error, {:ok, workdir}} ->
        {:ok, pid} = JobRunner.start_link(job_runner_opts(opts, workdir, outbox))
        pid

      {:error, :error} ->
        nil
    end
  end

  @doc """
  The options of the `PipeMaestroRunner.JobRunner` for a connection's
  options: its capacity is the hello's, and what it reports goes to `owner`.
  """
  @spec job_runner_opts(keyword(), Path.t(), GenServer.server()) :: keyword()
  def job_runner_opts(opts, workdir, owner) do
    %Hello{capacity: capacity} = Keyword.fetch!(opts, :hello)
    %{url: url, token: token} = Keyword.fetch!(opts, :config)
    job_opts = Keyword.take(opts, [:executable, :kill_after, :root, :telemetry])
    # The job's files go to the same control plane, as this runner.
    files = %{url: url, token: token}
    [owner: owner, workdir: workdir, capacity: capacity, files: files] ++ job_opts
  end

  @impl Slipstream
  def handle_connect(socket) do
    socket = assign(socket, directories: Directories.scan(socket.assigns.root))
    {:ok, join(socket, socket.assigns.topic, hello_payload(socket))}
  end

  # Sent on every (re)join, so it carries the jobs running and the directories
  # offered at that moment.
  defp hello_payload(%{assigns: %{hello: hello, job_runner: job_runner} = assigns}) do
    running = if job_runner, do: JobRunner.running_job_ids(job_runner), else: []
    running = Enum.uniq(running ++ OutboxServer.finished_job_ids(assigns.outbox))
    Hello.to_map(%{hello | running_job_ids: running, directories: assigns.directories})
  end

  @impl Slipstream
  def handle_join(_topic, reply, socket) do
    notify(socket, {:joined, reply})
    if socket.assigns.logs, do: LogCollector.attach(self(), RunnerLog.logs?(reply))
    # The platform forgets nothing it was told, but this is a new channel
    # process: the next measure is pushed even if unchanged.
    socket = assign(socket, usage: nil)

    socket =
      Enum.reduce(OutboxServer.joined(socket.assigns.outbox), socket, fn {id, event, payload},
                                                                         acc ->
        send_out(acc, id, event, payload)
      end)

    {:ok, socket |> measure_usage() |> sample_health() |> run_doctor(nil)}
  end

  @impl Slipstream
  def handle_reply(ref, _reply, socket) do
    # An error reply settles a message too: sending it again would not change
    # the answer.
    :ok = OutboxServer.confirmed(socket.assigns.outbox, ref)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect({:error, {:upgrade_failure, %{status_code: status}}}, socket)
      when status in [401, 403] do
    notify(socket, :rejected)
    {:stop, :normal, socket}
  end

  # Draining, it does not connect again: the runner is about to update.
  def handle_disconnect(_reason, %{assigns: %{draining: %{}}} = socket), do: {:ok, socket}

  def handle_disconnect(reason, socket) do
    notify(socket, {:disconnected, reason})

    LogCollector.capture(:warning, "Conexão com a plataforma perdida: #{inspect(reason)}", %{
      runner_event: "connection_lost",
      event_attrs: %{"reason" => inspect(reason, limit: 5)}
    })

    case reconnect(socket) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  @impl Slipstream
  def handle_topic_close(_topic, {:failed_to_join, %{"reason" => "outdated"} = refusal}, socket),
    do: {:ok, drain(socket, refusal)}

  def handle_topic_close(topic, _reason, socket) do
    socket = assign(socket, directories: Directories.scan(socket.assigns.root))
    rejoin(socket, topic, hello_payload(socket))
  end

  @impl Slipstream
  def handle_message(_topic, "job:assign", payload, %{assigns: %{job_runner: pid}} = socket)
      when is_pid(pid) do
    case Job.from_map(payload) do
      {:ok, job} -> JobRunner.enqueue(pid, job)
      {:error, reason} -> Logger.warning("Job inválido recebido da plataforma: #{reason}")
    end

    {:ok, socket}
  end

  def handle_message(
        _topic,
        "job:cancel",
        %{"job_id" => id},
        %{assigns: %{job_runner: pid}} = socket
      )
      when is_pid(pid) do
    JobRunner.cancel(pid, id)
    {:ok, socket}
  end

  def handle_message(
        _topic,
        "job:credential",
        %{"job_id" => id, "git_credential" => %{"username" => _, "password" => _} = credential},
        %{assigns: %{job_runner: pid}} = socket
      )
      when is_pid(pid) do
    JobRunner.renew_credential(pid, id, credential)
    {:ok, socket}
  end

  def handle_message(_topic, "worktree:remove", payload, %{assigns: %{job_runner: pid}} = socket)
      when is_pid(pid) do
    case Worktree.parse_remove(payload) do
      {:ok, %{"task_id" => task_id, "directory" => directory}} ->
        JobRunner.remove_worktree(pid, task_id, directory)

      {:error, reason} ->
        Logger.warning("Pedido de remoção de worktree inválido: #{reason}")
    end

    {:ok, socket}
  end

  def handle_message(_topic, "runner:doctor", %{"request_id" => id}, socket)
      when is_binary(id) and is_integer(socket.assigns.doctor_every),
      do: {:ok, run_doctor(socket, id)}

  def handle_message(_topic, event, _payload, socket) do
    Logger.warning("Mensagem da plataforma ignorada por este runner: #{event}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_info(:rescan, socket) do
    directories = Directories.scan(socket.assigns.root)
    schedule_rescan(socket)

    if directories != socket.assigns.directories and joined?(socket, socket.assigns.topic) do
      _pushed =
        push(socket, socket.assigns.topic, "runner:directories", %{"directories" => directories})

      {:noreply, assign(socket, directories: directories)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:measure_usage, socket), do: {:noreply, measure_usage(socket)}

  def handle_info(:sample_health, socket),
    do: {:noreply, sample_health(assign(socket, health_timer: nil))}

  def handle_info(:run_doctor, socket),
    do: {:noreply, run_doctor(assign(socket, doctor_timer: nil), nil)}

  def handle_info({ref, checks}, %{assigns: %{doctor: ref}} = socket) do
    Process.demonitor(ref, [:flush])
    %{doctor_request: request, doctor_every: every} = socket.assigns

    if joined?(socket, socket.assigns.topic) do
      payload = RunnerDoctor.to_map(checks, DateTime.utc_now(:second), request)
      _pushed = push(socket, socket.assigns.topic, RunnerDoctor.event(), payload)
    end

    timer = Process.send_after(self(), :run_doctor, every)
    {:noreply, assign(socket, doctor: nil, doctor_request: nil, doctor_timer: timer)}
  end

  def handle_info({ref, {sample, cpu}}, %{assigns: %{sampling: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    if joined?(socket, socket.assigns.topic),
      do: _pushed = push(socket, socket.assigns.topic, RunnerHealth.event(), sample)

    timer = Process.send_after(self(), :sample_health, socket.assigns.health_every)
    {:noreply, assign(socket, sampling: nil, cpu: cpu, health_timer: timer)}
  end

  # What the agent is writing: worth showing now or never, so it skips the
  # outbox and is dropped while disconnected.
  def handle_info({:job_live, event, payload}, socket) do
    if joined?(socket, socket.assigns.topic),
      do: _pushed = push(socket, socket.assigns.topic, event, payload)

    {:noreply, socket}
  end

  def handle_info({ref, usage}, %{assigns: %{measuring: ref}} = socket) do
    Process.demonitor(ref, [:flush])
    Process.send_after(self(), :measure_usage, socket.assigns.usage_every)
    socket = assign(socket, measuring: nil)

    if usage != socket.assigns.usage and joined?(socket, socket.assigns.topic) do
      _pushed = push(socket, socket.assigns.topic, Worktree.usage_event(), usage)
      {:noreply, assign(socket, usage: usage)}
    else
      {:noreply, socket}
    end
  end

  # What the job runner reports goes to the platform through the outbox; while
  # disconnected it waits there for the next join.
  def handle_info({:outbox_out, id, event, payload}, socket) do
    tell_job(socket, event, payload)
    {:noreply, socket |> tell_drops() |> send_out(id, event, payload)}
  end

  def handle_info({:job_out, event, payload}, socket) do
    tell_job(socket, event, payload)
    {:noreply, add_out(socket, event, payload)}
  end

  def handle_info(:drain_check, socket), do: drain_check(socket)

  # The runner's log, in batches (`PipeMaestroRunner.LogCollector`).
  def handle_info({:runner_log, lines}, socket),
    do: {:noreply, add_out(socket, RunnerLog.event(), %{"lines" => lines})}

  defp tell_job(socket, "job:started", payload),
    do: notify(socket, {:job_started, payload["job_id"]})

  defp tell_job(socket, "job:finished", payload), do: notify(socket, {:job_finished, payload})
  defp tell_job(_socket, _event, _payload), do: :ok

  defp add_out(socket, event, payload) do
    id = OutboxServer.add(socket.assigns.outbox, event, payload)
    socket |> tell_drops() |> send_out(id, event, payload)
  end

  # Before the update: no more jobs start, the running ones go on to their
  # end, and the outbox waits in its file for the runner that comes back.
  defp drain(socket, refusal) do
    %{job_runner: job_runner, drain_timeout_ms: timeout} = socket.assigns
    running = if job_runner, do: JobRunner.running_job_ids(job_runner), else: []
    if job_runner, do: :ok = JobRunner.drain(job_runner)

    LogCollector.capture(
      :info,
      "Recusado pela versão: terminando #{length(running)} job(s) antes de atualizar.",
      %{
        runner_event: "update_draining",
        event_attrs: %{"jobs" => length(running), "timeout_ms" => timeout}
      }
    )

    send(self(), :drain_check)
    deadline = System.monotonic_time(:millisecond) + timeout
    assign(socket, draining: %{refusal: refusal, deadline: deadline, stopped: false})
  end

  @drain_check_ms 100
  # Stopped as lost, a job has `kill_after` (5 s by default) to go; past this,
  # the update goes on anyway.
  @stop_wait_ms 10_000

  defp drain_check(%{assigns: %{draining: draining, job_runner: job_runner}} = socket) do
    running = if job_runner, do: JobRunner.running_job_ids(job_runner), else: []
    now = System.monotonic_time(:millisecond)

    cond do
      running == [] or (draining.stopped and now > draining.deadline) ->
        :ok = OutboxServer.persist_all(socket.assigns.outbox)
        notify(socket, {:outdated, draining.refusal})
        {:stop, :normal, socket}

      not draining.stopped and now > draining.deadline ->
        Enum.each(running, &JobRunner.cancel(job_runner, &1, :lost))
        Process.send_after(self(), :drain_check, @drain_check_ms)
        draining = %{draining | stopped: true, deadline: now + @stop_wait_ms}
        {:noreply, assign(socket, draining: draining)}

      true ->
        Process.send_after(self(), :drain_check, @drain_check_ms)
        {:noreply, socket}
    end
  end

  # Telling the log takes room in the outbox too: once a minute at most.
  defp tell_drops(%{assigns: %{outbox: outbox, drops_told: {told, at}}} = socket) do
    dropped = OutboxServer.dropped(outbox)
    now = System.monotonic_time(:millisecond)

    if dropped > told and (at == nil or now - at >= 60_000) do
      LogCollector.capture(
        :warning,
        "A fila de envio encheu: #{dropped - told} mensagens descartadas.",
        %{runner_event: "outbox_dropped", event_attrs: %{"count" => dropped - told}}
      )

      assign(socket, drops_told: {dropped, now})
    else
      socket
    end
  end

  defp send_out(socket, id, event, payload) do
    with true <- joined?(socket, socket.assigns.topic),
         {:ok, ref} <- push(socket, socket.assigns.topic, event, payload) do
      :ok = OutboxServer.sent(socket.assigns.outbox, id, ref)
      socket
    else
      _not_sent -> socket
    end
  end

  # `du` may take a while on large worktrees: it runs in a task, one at a time.
  defp measure_usage(%{assigns: %{workdir: nil}} = socket), do: socket
  defp measure_usage(%{assigns: %{measuring: ref}} = socket) when is_reference(ref), do: socket

  defp measure_usage(socket) do
    workdir = socket.assigns.workdir
    assign(socket, measuring: Task.async(fn -> Disk.usage(workdir) end).ref)
  end

  # The diagnosis runs commands (`gh auth status` may reach the network): in a
  # task, one at a time. A request while one runs is answered by it.
  defp run_doctor(%{assigns: %{doctor_every: nil}} = socket, _request), do: socket

  defp run_doctor(%{assigns: %{doctor: ref}} = socket, request) when is_reference(ref),
    do: if(request, do: assign(socket, doctor_request: request), else: socket)

  defp run_doctor(%{assigns: assigns} = socket, request) do
    if assigns.doctor_timer, do: Process.cancel_timer(assigns.doctor_timer)

    opts =
      Keyword.merge(
        [
          config: {:ok, assigns.config},
          workdir: assigns.workdir || Config.workdir(),
          reach: fn _url -> :ok end
        ],
        assigns.doctor_opts
      )

    task = Task.async(fn -> Doctor.run(opts) end)
    assign(socket, doctor: task.ref, doctor_request: request, doctor_timer: nil)
  end

  # Commands that may take a moment (`ps`, `df`): in a task, one at a time.
  # A join samples at once; the timer it replaces is dropped.
  defp sample_health(%{assigns: %{health_every: nil}} = socket), do: socket
  defp sample_health(%{assigns: %{sampling: ref}} = socket) when is_reference(ref), do: socket

  defp sample_health(%{assigns: assigns} = socket) do
    if assigns.health_timer, do: Process.cancel_timer(assigns.health_timer)

    running =
      if assigns.job_runner, do: length(JobRunner.running_job_ids(assigns.job_runner)), else: 0

    opts = [
      workdir: assigns.workdir,
      outbox_pending: OutboxServer.size(assigns.outbox),
      running_jobs: running,
      cpu: assigns.cpu
    ]

    assign(socket, sampling: Task.async(fn -> Health.sample(opts) end).ref, health_timer: nil)
  end

  defp notify(%{assigns: %{notify: pid}}, event) when is_pid(pid),
    do: send(pid, {:runner_connection, event})

  defp notify(_socket, _event), do: :ok

  # Quick retries first, then settle at 30s so a long outage does not hammer
  # the platform.
  defp backoff, do: [500, 1_000, 2_000, 5_000, 10_000, 30_000]
end
