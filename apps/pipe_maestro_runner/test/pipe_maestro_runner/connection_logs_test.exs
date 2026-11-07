defmodule PipeMaestroRunner.ConnectionLogsTest do
  # The log collector has a name.
  use Slipstream.SocketTest, async: false

  alias PipeMaestroRunner.{Connection, Host, LogCollector}

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

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!({LogCollector, flush_every: 60_000, secrets: ["cpr_token"]})
    {:ok, hello} = Host.hello()

    client =
      start_supervised!(
        {Connection,
         config: @config,
         hello: hello,
         workdir: dir,
         logs: true,
         connect_options: [test_mode?: true]}
      )

    %{client: client}
  end

  # In test mode each push waits for the test to take it, in order: what the
  # collector held goes as the join attaches it, before the worktrees' usage.
  defp usage, do: assert_push("runner:r1", "worktree:usage", _usage, _ref, 5_000)

  test "the log goes to the platform in batches, redacted", %{client: client} do
    LogCollector.capture(:info, "antes do join, com cpr_token")
    connect_and_assert_join(client, "runner:r1", _params, {:ok, %{"runner_id" => "r1"}})

    assert_push("runner:r1", "runner:log", %{"lines" => [first]}, _ref, 2_000)
    assert first["message"] == "antes do join, com [redigido]"
    usage()

    LogCollector.capture(:warning, "depois do join")
    LogCollector.flush()

    assert_push(
      "runner:r1",
      "runner:log",
      %{"lines" => [%{"message" => "depois do join"}]},
      _ref,
      2_000
    )
  end

  test "when the workspace keeps no log, only the events go", %{client: client} do
    reply = %{"runner_id" => "r1", "telemetry" => %{"logs" => false}}
    connect_and_assert_join(client, "runner:r1", _params, {:ok, reply})
    usage()

    LogCollector.capture(:info, "comum")
    LogCollector.capture(:error, "falhou", %{runner_event: "update_failed", event_attrs: %{}})
    LogCollector.flush()

    assert_push(
      "runner:r1",
      "runner:log",
      %{"lines" => [%{"event" => "update_failed"}]},
      _ref,
      2_000
    )
  end

  test "a dropped connection is told once it is back", %{client: client} do
    connect_and_assert_join(client, "runner:r1", _params, {:ok, %{"runner_id" => "r1"}})
    usage()
    disconnect(client, :closed)
    connect_and_assert_join(client, "runner:r1", _params, {:ok, %{"runner_id" => "r1"}})

    assert_push("runner:r1", "runner:log", %{"lines" => lines}, _ref, 2_000)
    assert Enum.any?(lines, &(&1["event"] == "connection_lost"))
  end
end
