defmodule ClaudeControlPlaneWeb.RunnerDeviceController do
  @moduledoc """
  The device flow a runner signs in with (see `docs/specs/protocolo-runner.md`):
  it asks for a code, shows the person a URL and a short code, and polls until
  someone approves it in the browser.
  """
  use ClaudeControlPlaneWeb, :controller

  alias ClaudeControlPlane.{Runners, Workspaces}
  alias ClaudeControlPlaneProtocol.Hello

  @doc "Starts a sign-in for the runner described in the body."
  @spec create_code(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_code(conn, params) do
    with {:ok, hello} <- Hello.from_map(Map.get(params, "hello", %{})),
         true <- hello.protocol_version in ClaudeControlPlaneProtocol.supported_versions() do
      {:ok, _auth, device_code, user_code} =
        Runners.start_device_authorization(hello, params["name"])

      activate_url = base_url(conn) <> ~p"/runners/activate"

      json(conn, %{
        device_code: device_code,
        user_code: user_code,
        verification_uri: activate_url,
        verification_uri_complete: activate_url <> "?" <> URI.encode_query(code: user_code),
        expires_in: Runners.authorization_ttl_seconds(),
        interval: Runners.poll_interval_seconds()
      })
    else
      {:error, reason} -> error(conn, :invalid_request, reason)
      false -> error(conn, :invalid_request, "unsupported protocol version")
    end
  end

  @doc "Answers a polling runner: its token once approved, or why not yet."
  @spec create_token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_token(conn, %{"device_code" => device_code}) when is_binary(device_code) do
    case Runners.exchange_device_code(device_code) do
      {:ok, runner, token} ->
        workspace = Workspaces.get_workspace!(runner.workspace_id)

        json(conn, %{
          runner_token: token,
          runner: %{id: runner.id, name: runner.name},
          workspace: %{name: workspace.name, slug: workspace.slug}
        })

      {:error, code} ->
        error(conn, code, nil)
    end
  end

  def create_token(conn, _params), do: error(conn, :invalid_request, "device_code is required")

  defp error(conn, code, description) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: code, error_description: description})
  end

  # The URL the runner reached us at, so the link it prints is one that works
  # from where it runs.
  defp base_url(conn) do
    URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
  end
end
