defmodule PipeMaestroRunner.Connection do
  @moduledoc """
  The runner's connection to the control plane: an outbound WebSocket that
  authenticates with the runner's token, joins `runner:<id>` announcing this
  machine, and reconnects with backoff when the network drops.

  When the platform refuses the connection itself (HTTP 403: the token was
  revoked or the protocol version is no longer accepted) reconnecting cannot
  help, so the connection stops and reports `:rejected`.

  Given a `:workdir`, it also runs jobs: it starts a
  `PipeMaestroRunner.JobRunner` with the capacity announced in the
  hello, hands it the `job:assign` and
  `job:cancel` messages, pushes back what it reports, and tells the control
  plane which jobs survive a reconnection (`Hello.running_job_ids`).

  What it reports is kept until the control plane replies
  (`PipeMaestroRunner.Outbox`) and sent again, in order, after every
  join; a job whose end the control plane has not confirmed still counts as
  running, so a reconnection does not fail it. With an `:outbox_path`, the
  ends survive a restart too.

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

  Progress is reported to `:notify` (a pid) as `{:runner_connection, event}`
  with `event` one of `{:joined, reply}`, `{:disconnected, reason}`,
  `:rejected`, `{:job_started, job_id}` and `{:job_finished, payload}`.
  """
  use Slipstream, restart: :temporary

  require Logger

  alias PipeMaestroProtocol.{Hello, Job, Worktree}
  alias PipeMaestroRunner.{Directories, Disk, JobRunner, Outbox}

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
    job_runner = start_job_runner(opts)

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
        outbox: Outbox.new(20_000, Keyword.get(opts, :outbox_path))
      )

    schedule_rescan(socket)
    {:ok, socket}
  end

  defp schedule_rescan(%{assigns: %{root: nil}}), do: :ok

  defp schedule_rescan(%{assigns: %{rescan_every: every}}),
    do: Process.send_after(self(), :rescan, every)

  defp start_job_runner(opts) do
    case Keyword.fetch(opts, :workdir) do
      {:ok, workdir} ->
        %Hello{capacity: capacity} = Keyword.fetch!(opts, :hello)
        job_opts = Keyword.take(opts, [:executable, :kill_after, :root, :telemetry])

        {:ok, pid} =
          JobRunner.start_link([owner: self(), workdir: workdir, capacity: capacity] ++ job_opts)

        pid

      :error ->
        nil
    end
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
    running = Enum.uniq(running ++ Outbox.job_ids(assigns.outbox))
    Hello.to_map(%{hello | running_job_ids: running, directories: assigns.directories})
  end

  @impl Slipstream
  def handle_join(_topic, reply, socket) do
    notify(socket, {:joined, reply})
    # The platform forgets nothing it was told, but this is a new channel
    # process: the next measure is pushed even if unchanged.
    socket = assign(socket, usage: nil, outbox: Outbox.forget_refs(socket.assigns.outbox))

    socket =
      Enum.reduce(Outbox.pending(socket.assigns.outbox), socket, fn {id, event, payload}, acc ->
        send_out(acc, id, event, payload)
      end)

    {:ok, measure_usage(socket)}
  end

  @impl Slipstream
  def handle_reply(ref, _reply, socket) do
    # An error reply settles a message too: sending it again would not change
    # the answer.
    {:ok, assign(socket, outbox: Outbox.confirmed(socket.assigns.outbox, ref))}
  end

  @impl Slipstream
  def handle_disconnect({:error, {:upgrade_failure, %{status_code: status}}}, socket)
      when status in [401, 403] do
    notify(socket, :rejected)
    {:stop, :normal, socket}
  end

  def handle_disconnect(reason, socket) do
    notify(socket, {:disconnected, reason})

    case reconnect(socket) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  @impl Slipstream
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
  def handle_info({:job_out, event, payload}, socket) do
    {id, outbox} = Outbox.add(socket.assigns.outbox, event, payload)
    socket = send_out(assign(socket, outbox: outbox), id, event, payload)

    case event do
      "job:started" -> notify(socket, {:job_started, payload["job_id"]})
      "job:finished" -> notify(socket, {:job_finished, payload})
      _event -> :ok
    end

    {:noreply, socket}
  end

  defp send_out(socket, id, event, payload) do
    with true <- joined?(socket, socket.assigns.topic),
         {:ok, ref} <- push(socket, socket.assigns.topic, event, payload) do
      assign(socket, outbox: Outbox.sent(socket.assigns.outbox, id, ref))
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

  defp notify(%{assigns: %{notify: pid}}, event) when is_pid(pid),
    do: send(pid, {:runner_connection, event})

  defp notify(_socket, _event), do: :ok

  # Quick retries first, then settle at 30s so a long outage does not hammer
  # the platform.
  defp backoff, do: [500, 1_000, 2_000, 5_000, 10_000, 30_000]
end
