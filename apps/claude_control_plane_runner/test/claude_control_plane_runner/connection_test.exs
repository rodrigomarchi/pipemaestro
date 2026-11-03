defmodule ClaudeControlPlaneRunner.ConnectionTest do
  use Slipstream.SocketTest

  alias ClaudeControlPlaneProtocol.Hello
  alias ClaudeControlPlaneRunner.{Connection, Host}

  @config %{
    url: "http://localhost:4000",
    runner_id: "r1",
    runner_name: "build-01",
    token: "cpr_token",
    workspace_name: "Acme",
    workspace_slug: "acme",
    labels: [],
    capacity: nil
  }

  setup do
    {:ok, hello} = Host.hello()

    client =
      start_supervised!(
        {Connection,
         config: @config, hello: hello, notify: self(), connect_options: [test_mode?: true]}
      )

    %{client: client, hello: hello}
  end

  test "joins its topic announcing the hello", %{client: client, hello: hello} do
    connect_and_assert_join(client, "runner:r1", params, {:ok, %{"name" => "build-01"}})

    assert params == Hello.to_map(hello)
    assert_receive {:runner_connection, {:joined, %{"name" => "build-01"}}}
  end

  test "stops when the platform refuses it", %{client: client} do
    ref = Process.monitor(client)
    accept_connect(client)

    disconnect(client, {:error, {:upgrade_failure, %{status_code: 403}}})

    assert_receive {:runner_connection, :rejected}
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
  end

  test "reports a dropped connection and reconnects", %{client: client} do
    connect_and_assert_join(client, "runner:r1", _params, :ok)

    disconnect(client, :closed)

    assert_receive {:runner_connection, {:disconnected, :closed}}
    connect_and_assert_join(client, "runner:r1", _params, :ok)
  end
end
