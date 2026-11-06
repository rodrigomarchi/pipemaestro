defmodule PipeMaestroRunner.DeviceLoginTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.{DeviceLogin, Host}

  @code_response %{
    "device_code" => "dev-secret",
    "user_code" => "WDJB-MJHT",
    "verification_uri" => "http://localhost:4000/runners/activate",
    "verification_uri_complete" => "http://localhost:4000/runners/activate?code=WDJB-MJHT",
    "expires_in" => 600,
    "interval" => 5
  }

  @token_response %{
    "runner_token" => "cpr_token",
    "runner" => %{"id" => "r1", "name" => "build-01"},
    "workspace" => %{"name" => "Acme", "slug" => "acme"}
  }

  setup do
    {:ok, hello} = Host.hello()
    %{hello: hello}
  end

  # Answers the code request, then each poll with the next of `polls`.
  defp stub(name, polls) do
    {:ok, agent} = Agent.start_link(fn -> polls end)

    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/api/runner/device/code" ->
          Req.Test.json(conn, @code_response)

        "/api/runner/device/token" ->
          {status, body} = next_poll(agent)
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
    end)
  end

  defp next_poll(agent), do: Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)

  defp run(name, hello, test_pid) do
    DeviceLogin.run("http://localhost:4000", hello,
      req_options: [plug: {Req.Test, name}],
      sleep: fn ms -> send(test_pid, {:slept, ms}) end,
      on_code: fn code -> send(test_pid, {:code, code}) end
    )
  end

  test "shows the code, waits through pending and slow_down, returns the token", %{hello: hello} do
    stub(__MODULE__.Ok, [
      {400, %{"error" => "authorization_pending"}},
      {400, %{"error" => "slow_down"}},
      {200, @token_response}
    ])

    assert {:ok, result} = run(__MODULE__.Ok, hello, self())

    assert result == %{
             token: "cpr_token",
             runner_id: "r1",
             runner_name: "build-01",
             workspace_name: "Acme",
             workspace_slug: "acme"
           }

    assert_received {:code, %{user_code: "WDJB-MJHT"}}
    assert_received {:slept, 5_000}
    assert_received {:slept, 5_000}
    assert_received {:slept, 10_000}
  end

  test "stops on denial and on expiry", %{hello: hello} do
    stub(__MODULE__.Denied, [{400, %{"error" => "access_denied"}}])
    assert run(__MODULE__.Denied, hello, self()) == {:error, :denied}

    stub(__MODULE__.Expired, [{400, %{"error" => "expired_token"}}])
    assert run(__MODULE__.Expired, hello, self()) == {:error, :expired}
  end

  test "an outdated runner is told the version the platform asks for and where to get it", %{
    hello: hello
  } do
    refusal = %{
      "error" => "outdated",
      "reason" => "outdated",
      "version" => "2026-11-04.02",
      "runner_version" => "2026-11-04.01",
      "download_url" => "https://pipemaestro.app/downloads/runner/"
    }

    Req.Test.stub(__MODULE__.Outdated, fn conn ->
      conn |> Plug.Conn.put_status(409) |> Req.Test.json(refusal)
    end)

    assert {:error, {:outdated, ^refusal}} = run(__MODULE__.Outdated, hello, self())
    refute_received {:code, _}

    message = PipeMaestroRunner.Update.message(refusal)
    assert message =~ "versão 2026-11-04.01"
    assert message =~ "pede a versão 2026-11-04.02 do runner"
    assert message =~ "https://pipemaestro.app/downloads/runner/"
  end

  test "reports unexpected answers", %{hello: hello} do
    stub(__MODULE__.Weird, [{400, %{"error" => "nope"}}])
    assert {:error, {:unexpected, :invalid_request}} = run(__MODULE__.Weird, hello, self())

    stub(__MODULE__.Server, [{500, %{"oops" => true}}])
    assert {:error, {:unexpected, %{"oops" => true}}} = run(__MODULE__.Server, hello, self())

    Req.Test.stub(__MODULE__.BadCode, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_request"})
    end)

    assert {:error, {:unexpected, %{"error" => "invalid_request"}}} =
             run(__MODULE__.BadCode, hello, self())
  end

  test "reports an unreachable platform", %{hello: hello} do
    Req.Test.stub(__MODULE__.Down, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, {:unreachable, %Req.TransportError{}}} = run(__MODULE__.Down, hello, self())
  end
end
