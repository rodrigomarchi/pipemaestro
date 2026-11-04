defmodule PipeMaestroWeb.RunnerDeviceControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  alias PipeMaestro.Runners
  alias PipeMaestroProtocol.Hello

  defp hello_params(overrides \\ %{}) do
    hello_fixture() |> Hello.to_map() |> Map.merge(overrides)
  end

  test "issues a code and the activation URL on the host the runner used", %{conn: conn} do
    body =
      conn |> post(~p"/api/runner/device/code", %{hello: hello_params()}) |> json_response(200)

    assert body["user_code"] =~ ~r/^[A-Z]{4}-[A-Z]{4}$/
    assert body["verification_uri"] == "http://www.example.com/runners/activate"
    assert body["verification_uri_complete"] =~ "code=#{body["user_code"]}"
    assert body["interval"] == Runners.poll_interval_seconds()
  end

  test "limits how many codes one address asks for in a minute", %{conn: conn} do
    ip = {10, 9, System.unique_integer([:positive]) |> rem(250), 1}

    ask = fn ->
      %{conn | remote_ip: ip} |> post(~p"/api/runner/device/code", %{hello: hello_params()})
    end

    for _ <- 1..10, do: assert(ask.().status == 200)

    conn = ask.()
    assert conn.status == 429
    assert json_response(conn, 429)["error"] == "slow_down"
    assert [retry_after] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..60
  end

  test "rejects a bad hello or an unsupported protocol", %{conn: conn} do
    assert %{"error" => "invalid_request"} =
             conn
             |> post(~p"/api/runner/device/code", %{hello: hello_params(%{"capacity" => 0})})
             |> json_response(400)

    assert %{"error_description" => "unsupported protocol version"} =
             build_conn()
             |> post(~p"/api/runner/device/code", %{
               hello: hello_params(%{"protocol_version" => 999})
             })
             |> json_response(400)
  end

  test "the token endpoint answers pending, then the token once approved", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Acme"})
    user = member_fixture(workspace)

    %{"device_code" => device_code, "user_code" => user_code} =
      conn
      |> post(~p"/api/runner/device/code", %{hello: hello_params(), name: "build-01"})
      |> json_response(200)

    assert %{"error" => "authorization_pending"} =
             build_conn()
             |> post(~p"/api/runner/device/token", %{device_code: device_code})
             |> json_response(400)

    auth = Runners.get_pending_authorization(user_code)
    {:ok, _runner} = Runners.approve_device_authorization(auth, user, workspace, "build-01")

    body =
      build_conn()
      |> post(~p"/api/runner/device/token", %{device_code: device_code})
      |> json_response(200)

    assert "cpr_" <> _ = body["runner_token"]
    assert body["runner"]["name"] == "build-01"
    assert body["workspace"] == %{"name" => "Acme", "slug" => workspace.slug}
  end

  test "the token endpoint needs a device code", %{conn: conn} do
    assert %{"error" => "invalid_request"} =
             conn |> post(~p"/api/runner/device/token", %{}) |> json_response(400)
  end
end
