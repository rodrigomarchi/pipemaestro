defmodule ClaudeControlPlaneWeb.RunnerSocket do
  @moduledoc """
  The socket runners connect out to. A runner authenticates with the token it
  received from the device flow and states the protocol version it speaks;
  either being wrong refuses the connection (HTTP 403 on the upgrade).
  """
  use Phoenix.Socket

  alias ClaudeControlPlane.Runners
  alias ClaudeControlPlaneWeb.RunnerStatus

  channel "runner:*", ClaudeControlPlaneWeb.RunnerChannel

  @impl true
  def connect(%{"token" => token, "protocol_version" => version}, socket, _connect_info) do
    with true <- supported_version?(version),
         %{} = runner <- Runners.authenticate_runner(token) do
      {:ok, assign(socket, :runner, runner)}
    else
      _refused -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: RunnerStatus.socket_id(socket.assigns.runner.id)

  defp supported_version?(version) do
    case Integer.parse(to_string(version)) do
      {number, ""} -> number in ClaudeControlPlaneProtocol.supported_versions()
      _other -> false
    end
  end
end
