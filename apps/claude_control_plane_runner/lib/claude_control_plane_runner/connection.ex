defmodule ClaudeControlPlaneRunner.Connection do
  @moduledoc """
  The runner's connection to the control plane: an outbound WebSocket that
  authenticates with the runner's token, joins `runner:<id>` announcing this
  machine, and reconnects with backoff when the network drops.

  When the platform refuses the connection itself (HTTP 403: the token was
  revoked or the protocol version is no longer accepted) reconnecting cannot
  help, so the connection stops and reports `:rejected`.

  Given a `:workdir`, it also runs jobs: it starts a
  `ClaudeControlPlaneRunner.JobRunner`, hands it the `job:assign` and
  `job:cancel` messages, pushes back what it reports, and tells the control
  plane which jobs survive a reconnection (`Hello.running_job_ids`).

  Progress is reported to `:notify` (a pid) as `{:runner_connection, event}`
  with `event` one of `{:joined, reply}`, `{:disconnected, reason}`,
  `:rejected`, `{:job_started, job_id}` and `{:job_finished, payload}`.
  """
  use Slipstream, restart: :temporary

  require Logger

  alias ClaudeControlPlaneProtocol.{Hello, Job}
  alias ClaudeControlPlaneRunner.JobRunner

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
        path: ClaudeControlPlaneProtocol.socket_path() <> "/websocket",
        query:
          URI.encode_query(token: token, protocol_version: ClaudeControlPlaneProtocol.version())
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
        topic: ClaudeControlPlaneProtocol.runner_topic(config.runner_id),
        hello: hello,
        notify: Keyword.get(opts, :notify),
        job_runner: job_runner
      )

    {:ok, socket}
  end

  defp start_job_runner(opts) do
    case Keyword.fetch(opts, :workdir) do
      {:ok, workdir} ->
        job_opts = Keyword.take(opts, [:executable, :kill_after])
        {:ok, pid} = JobRunner.start_link([owner: self(), workdir: workdir] ++ job_opts)
        pid

      :error ->
        nil
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    {:ok, join(socket, socket.assigns.topic, hello_payload(socket))}
  end

  # Sent on every (re)join, so it carries the jobs running at that moment.
  defp hello_payload(%{assigns: %{hello: hello, job_runner: nil}}), do: Hello.to_map(hello)

  defp hello_payload(%{assigns: %{hello: hello, job_runner: job_runner}}),
    do: Hello.to_map(%{hello | running_job_ids: JobRunner.running_job_ids(job_runner)})

  @impl Slipstream
  def handle_join(_topic, reply, socket) do
    notify(socket, {:joined, reply})
    {:ok, socket}
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

  def handle_message(_topic, event, _payload, socket) do
    Logger.warning("Mensagem da plataforma ignorada por este runner: #{event}")
    {:ok, socket}
  end

  # What the job runner reports goes to the platform. While disconnected the
  # push fails and the event is lost; the run itself goes on.
  @impl Slipstream
  def handle_info({:job_out, event, payload}, socket) do
    _pushed = push(socket, socket.assigns.topic, event, payload)

    case event do
      "job:started" -> notify(socket, {:job_started, payload["job_id"]})
      "job:finished" -> notify(socket, {:job_finished, payload})
      _event -> :ok
    end

    {:noreply, socket}
  end

  defp notify(%{assigns: %{notify: pid}}, event) when is_pid(pid),
    do: send(pid, {:runner_connection, event})

  defp notify(_socket, _event), do: :ok

  # Quick retries first, then settle at 30s so a long outage does not hammer
  # the platform.
  defp backoff, do: [500, 1_000, 2_000, 5_000, 10_000, 30_000]
end
