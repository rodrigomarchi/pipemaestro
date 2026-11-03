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

  # After every join the runner reports its worktrees' disk usage; in test
  # mode the push holds the connection until the test takes it.
  defp assert_usage do
    assert_push("runner:r1", "worktree:usage", %{"count" => 0, "bytes" => 0}, _ref, 5_000)
  end

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
    assert_usage()
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
    assert_events(2..6)

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
    assert_events(1..4)

    disconnect(client, :closed)
    assert_receive {:runner_connection, {:disconnected, :closed}}
    connect_and_assert_join(client, "runner:r1", params, :ok)
    assert params["running_job_ids"] == ["j1"]

    # Nothing was confirmed: it all goes again, before anything new.
    assert_push("runner:r1", "job:started", %{"job_id" => "j1"})
    assert_events(1..4)
    assert_usage()

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

  test "runs as many jobs at once as the capacity it announced", %{tmp_dir: dir} do
    stop_supervised!(Connection)
    root = Path.join(dir, "src")
    for name <- ~w(a b), do: File.mkdir_p!(Path.join(root, name))
    {:ok, hello} = Host.hello(capacity: 2)

    client =
      start_supervised!(
        {Connection,
         config: @config,
         hello: hello,
         notify: self(),
         workdir: Path.join(dir, "workdir"),
         root: root,
         executable: {:ok, @fake},
         connect_options: [test_mode?: true]}
      )

    connect_and_assert_join(client, "runner:r1", _params, :ok)
    assert_usage()

    for {id, directory} <- [{"j1", "a"}, {"j2", "b"}] do
      push(client, "runner:r1", "job:assign", %{
        "id" => id,
        "prompt" => "devagar [lento]",
        "directory" => directory
      })
    end

    assert_push("runner:r1", "job:started", %{"job_id" => "j1"})
    assert_push("runner:r1", "job:started", %{"job_id" => "j2"})
  end

  test "removes a task's worktree when asked", %{client: client} do
    push(client, "runner:r1", "worktree:remove", %{"task_id" => "t1", "directory" => "app"})
    assert_push("runner:r1", "worktree:removed", %{"task_id" => "t1"}, _ref, 5_000)
  end

  # Takes the pushes of a whole run of job `id`, answering each with `reply`
  # (or leaving them unanswered with `nil`).
  defp take_run(client, id, reply) do
    assert_push("runner:r1", "job:started", %{"job_id" => ^id}, ref, 5_000)
    if reply, do: reply(client, ref, reply)

    for seq <- 1..6 do
      assert_push("runner:r1", "job:event", %{"job_id" => ^id, "seq" => ^seq}, ref, 5_000)
      if reply, do: reply(client, ref, reply)
    end

    assert_push("runner:r1", "job:finished", %{"job_id" => ^id}, ref, 5_000)
    if reply, do: reply(client, ref, reply)
  end

  test "what the platform did not confirm is sent again after reconnecting", %{client: client} do
    push(client, "runner:r1", "job:assign", %{"id" => "j1", "prompt" => "diga oi"})
    take_run(client, "j1", nil)

    disconnect(client, :closed)
    assert_receive {:runner_connection, {:disconnected, :closed}}

    # Until the platform has the end, the job still counts as running.
    connect_and_assert_join(client, "runner:r1", params, :ok)
    assert params["running_job_ids"] == ["j1"]
    take_run(client, "j1", :ok)
    assert_usage()

    disconnect(client, :closed)
    connect_and_assert_join(client, "runner:r1", params, :ok)
    assert params["running_job_ids"] == []
    assert_usage()
    refute_push("runner:r1", "job:started", _params)
  end

  test "an error reply also settles a message", %{client: client} do
    push(client, "runner:r1", "job:assign", %{"id" => "j1", "prompt" => "diga oi"})
    take_run(client, "j1", {:error, %{"reason" => "not_found"}})

    disconnect(client, :closed)
    connect_and_assert_join(client, "runner:r1", params, :ok)
    assert params["running_job_ids"] == []
  end

  test "relays what the agent is writing without keeping it", %{client: client} do
    push(client, "runner:r1", "job:assign", %{"id" => "j1", "prompt" => "oi [digitando]"})
    assert_push("runner:r1", "job:started", %{"job_id" => "j1"})
    assert_events(1..4)

    for text <- [
          "Pronto: ",
          "Pronto: gravei o prompt ",
          "Pronto: gravei o prompt em fake-claude.txt."
        ] do
      assert_push("runner:r1", "job:delta", %{"job_id" => "j1", "text" => ^text}, _ref, 5_000)
    end

    assert_events(5..6)
    assert_push("runner:r1", "job:finished", %{"job_id" => "j1"}, _ref, 5_000)

    # Unanswered, the deltas are not sent again after reconnecting.
    disconnect(client, :closed)
    connect_and_assert_join(client, "runner:r1", _params, :ok)
    assert_push("runner:r1", "job:started", %{"job_id" => "j1"})
    assert_events(1..6)
    assert_push("runner:r1", "job:finished", %{"job_id" => "j1"}, _ref, 5_000)
    refute_push("runner:r1", "job:delta", _params)
  end

  test "after a restart, sends the ends the platform never confirmed", %{tmp_dir: dir} do
    stop_supervised!(Connection)
    path = Path.join(dir, "outbox.bin")

    # What a previous run left unconfirmed when it stopped.
    {_id, _outbox} =
      ClaudeControlPlaneRunner.Outbox.new(20_000, path)
      |> ClaudeControlPlaneRunner.Outbox.add("job:finished", %{
        "job_id" => "j9",
        "status" => "succeeded"
      })

    {:ok, hello} = Host.hello()

    client =
      start_supervised!(
        {Connection,
         config: @config,
         hello: hello,
         notify: self(),
         workdir: Path.join(dir, "workdir"),
         outbox_path: path,
         executable: {:ok, @fake},
         connect_options: [test_mode?: true]}
      )

    connect_and_assert_join(client, "runner:r1", params, :ok)
    assert params["running_job_ids"] == ["j9"]
    assert_push("runner:r1", "job:finished", %{"job_id" => "j9", "status" => "succeeded"})
  end
end
