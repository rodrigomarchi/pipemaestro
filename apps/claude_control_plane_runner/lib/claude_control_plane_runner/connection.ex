defmodule ClaudeControlPlaneRunner.Connection do
  @moduledoc """
  The runner's connection to the control plane: an outbound WebSocket that
  authenticates with the runner's token, joins `runner:<id>` announcing this
  machine, and reconnects with backoff when the network drops.

  When the platform refuses the connection itself (HTTP 403: the token was
  revoked or the protocol version is no longer accepted) reconnecting cannot
  help, so the connection stops and reports `:rejected`.

  Progress is reported to `:notify` (a pid) as `{:runner_connection, event}`
  with `event` one of `{:joined, reply}`, `{:disconnected, reason}` and
  `:rejected`.
  """
  use Slipstream, restart: :temporary

  alias ClaudeControlPlaneProtocol.Hello

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

    # :connect_options reaches Slipstream as is (tests pass `test_mode?: true`).
    socket =
      [uri: websocket_url(config.url, config.token), reconnect_after_msec: backoff()]
      |> Keyword.merge(Keyword.get(opts, :connect_options, []))
      |> connect!()
      |> assign(
        topic: ClaudeControlPlaneProtocol.runner_topic(config.runner_id),
        hello: hello,
        notify: Keyword.get(opts, :notify)
      )

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    {:ok, join(socket, socket.assigns.topic, Hello.to_map(socket.assigns.hello))}
  end

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
    rejoin(socket, topic, Hello.to_map(socket.assigns.hello))
  end

  defp notify(%{assigns: %{notify: pid}}, event) when is_pid(pid),
    do: send(pid, {:runner_connection, event})

  defp notify(_socket, _event), do: :ok

  # Quick retries first, then settle at 30s so a long outage does not hammer
  # the platform.
  defp backoff, do: [500, 1_000, 2_000, 5_000, 10_000, 30_000]
end
