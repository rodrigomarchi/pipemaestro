defmodule PipeMaestroRunner.ConnectionHealthTest do
  use Slipstream.SocketTest

  alias PipeMaestroProtocol.RunnerHealth
  alias PipeMaestroRunner.{Connection, Host}

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

  defp start(dir, opts) do
    {:ok, hello} = Host.hello()

    start_supervised!(
      {Connection,
       [config: @config, hello: hello, workdir: dir, connect_options: [test_mode?: true]] ++ opts}
    )
  end

  test "samples the machine's health on join and then at the interval", %{tmp_dir: dir} do
    client = start(dir, health_every: 100)
    connect_and_assert_join(client, "runner:r1", _params, :ok)

    assert_push("runner:r1", "worktree:usage", _usage, _ref, 5_000)
    assert_push("runner:r1", "runner:health", sample, _ref, 5_000)
    assert {:ok, parsed} = RunnerHealth.parse(sample)
    assert parsed["running_jobs"] == 0
    assert parsed["outbox_pending"] == 0
    assert is_integer(parsed["disk_free_bytes"])

    assert_push("runner:r1", "runner:health", _sample, _ref, 2_000)
  end

  test "without an interval it sends no health", %{tmp_dir: dir} do
    client = start(dir, [])
    connect_and_assert_join(client, "runner:r1", _params, :ok)
    assert_push("runner:r1", "worktree:usage", _usage, _ref, 5_000)
    refute_push("runner:r1", "runner:health", _sample, 300)
  end
end
