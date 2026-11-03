defmodule ClaudeControlPlaneRunner.ConnectionJobsTest do
  use Slipstream.SocketTest

  alias ClaudeControlPlaneRunner.{Connection, Host}

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

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, hello} = Host.hello()

    client =
      start_supervised!(
        {Connection,
         config: @config,
         hello: hello,
         notify: self(),
         workdir: dir,
         executable: {:ok, @fake},
         connect_options: [test_mode?: true]}
      )

    connect_and_assert_join(client, "runner:r1", params, :ok)
    assert params["running_job_ids"] == []

    %{client: client}
  end

  # In test mode every push waits for the test to take it, in order.
  defp assert_events(seqs) do
    for seq <- seqs, do: assert_push("runner:r1", "job:event", %{"seq" => ^seq}, _ref, 5_000)
  end

  test "runs an assigned job and pushes its run back", %{client: client, tmp_dir: dir} do
    push(client, "runner:r1", "job:assign", %{"id" => "j1", "prompt" => "diga oi"})

    assert_push("runner:r1", "job:started", %{"job_id" => "j1"})
    assert_receive {:runner_connection, {:job_started, "j1"}}
    assert_push("runner:r1", "job:event", %{"job_id" => "j1", "seq" => 1, "type" => "system"})
    assert_events(2..5)

    assert_push(
      "runner:r1",
      "job:finished",
      %{"job_id" => "j1", "status" => "succeeded"},
      _ref,
      5_000
    )

    assert_receive {:runner_connection, {:job_finished, %{"status" => "succeeded"}}}

    assert File.read!(Path.join(dir, "fake-claude.txt")) == "diga oi\n"
  end

  test "a rejoin announces the job still running; cancel stops it", %{client: client} do
    push(client, "runner:r1", "job:assign", %{"id" => "j1", "prompt" => "devagar [lento]"})
    assert_push("runner:r1", "job:started", %{"job_id" => "j1"})
    assert_events(1..3)

    disconnect(client, :closed)
    assert_receive {:runner_connection, {:disconnected, :closed}}
    connect_and_assert_join(client, "runner:r1", params, :ok)
    assert params["running_job_ids"] == ["j1"]

    push(client, "runner:r1", "job:cancel", %{"job_id" => "j1"})

    assert_push(
      "runner:r1",
      "job:finished",
      %{"job_id" => "j1", "status" => "canceled"},
      _ref,
      5_000
    )
  end

  @tag :capture_log
  test "ignores an invalid job and unknown messages", %{client: client} do
    push(client, "runner:r1", "job:assign", %{"id" => "j1"})
    push(client, "runner:r1", "something:else", %{})

    refute_push("runner:r1", "job:started", _params)
    assert Process.alive?(client)
  end
end
