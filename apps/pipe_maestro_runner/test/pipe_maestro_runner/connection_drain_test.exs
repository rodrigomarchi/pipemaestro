defmodule PipeMaestroRunner.ConnectionDrainTest do
  use Slipstream.SocketTest

  alias PipeMaestroRunner.{Connection, Host, Outbox}

  @fake Path.expand("../support/fake_claude", __DIR__)

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

  @refusal %{"reason" => "outdated", "version" => "2026-11-07.01"}

  @moduletag :tmp_dir

  defp start(dir, drain_timeout_ms) do
    {:ok, hello} = Host.hello()
    outbox = Path.join(dir, "outbox.bin")

    client =
      start_supervised!(
        {Connection,
         config: @config,
         hello: hello,
         notify: self(),
         workdir: Path.join(dir, "workdir"),
         executable: {:ok, @fake},
         outbox_path: outbox,
         drain_timeout_ms: drain_timeout_ms,
         connect_options: [test_mode?: true]}
      )

    connect_and_assert_join(client, "runner:r1", _params, :ok)
    assert_push("runner:r1", "worktree:usage", _usage, _ref, 5_000)

    %{client: client, outbox: outbox}
  end

  # Starts a job, then has the platform refuse the rejoin for the runner's version.
  defp refuse_with_a_job_running(client, prompt) do
    push(client, "runner:r1", "job:assign", %{"id" => "j1", "prompt" => prompt})
    assert_push("runner:r1", "job:started", %{"job_id" => "j1"}, _ref, 5_000)

    disconnect(client, :closed)
    assert_receive {:runner_connection, {:disconnected, :closed}}
    connect_and_assert_join(client, "runner:r1", _params, {:error, @refusal})
  end

  defp kept(outbox) do
    for {_id, event, payload} <- Outbox.pending(Outbox.new(20_000, outbox)),
        do: {event, payload["job_id"], payload["status"]}
  end

  test "refused for its version, it lets the running job finish and keeps its end before updating",
       %{tmp_dir: dir} do
    %{client: client, outbox: outbox} = start(dir, 30_000)
    ref = Process.monitor(client)

    refuse_with_a_job_running(client, "devagar [gotejando]")

    # The job is not canceled: the update waits for it.
    refute_receive {:runner_connection, {:outdated, _refusal}}, 1_000
    assert_receive {:runner_connection, {:outdated, @refusal}}, 10_000

    assert {"job:finished", "j1", "succeeded"} in kept(outbox)
    assert {"job:started", "j1", nil} in kept(outbox)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
  end

  test "past the deadline, the job is stopped as lost: no end of it is kept", %{tmp_dir: dir} do
    %{client: client, outbox: outbox} = start(dir, 300)

    refuse_with_a_job_running(client, "devagar [lento]")

    assert_receive {:runner_connection, {:outdated, @refusal}}, 10_000
    refute Enum.any?(kept(outbox), &match?({"job:finished", "j1", _status}, &1))
    assert {"job:started", "j1", nil} in kept(outbox)
  end
end
