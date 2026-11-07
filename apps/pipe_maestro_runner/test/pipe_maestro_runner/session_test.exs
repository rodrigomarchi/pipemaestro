defmodule PipeMaestroRunner.SessionTest do
  use Slipstream.SocketTest

  alias PipeMaestroRunner.{Host, JobRunner, Session}

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

    session =
      start_supervised!(
        {Session,
         config: @config,
         hello: hello,
         notify: self(),
         workdir: Path.join(dir, "workdir"),
         executable: {:ok, @fake},
         outbox_path: Path.join(dir, "outbox.bin"),
         connect_options: [test_mode?: true]}
      )

    client = Session.connection(session)
    connect_and_assert_join(client, "runner:r1", _params, :ok)
    assert_push("runner:r1", "worktree:usage", _usage, _ref, 5_000)

    %{session: session, client: client}
  end

  defp wait_new_connection(session, old, tries \\ 100) do
    case Session.connection(session) do
      pid when is_pid(pid) and pid != old ->
        pid

      _same_or_none when tries > 0 ->
        Process.sleep(100)
        wait_new_connection(session, old, tries - 1)

      _ ->
        flunk("the connection was never started again")
    end
  end

  test "a crashed connection is started again; the job and what it reported live on",
       %{session: session, client: client} do
    push(client, "runner:r1", "job:assign", %{"id" => "j1", "prompt" => "devagar [lento]"})
    assert_push("runner:r1", "job:started", %{"job_id" => "j1"}, _ref, 5_000)
    assert_push("runner:r1", "job:event", %{"seq" => 1}, _ref, 5_000)

    job_runner = Session.job_runner(session)
    Process.exit(client, :kill)

    assert Process.alive?(session)
    assert Process.alive?(job_runner)
    assert JobRunner.running_job_ids(job_runner) == ["j1"]

    new = wait_new_connection(session, client)
    connect_and_assert_join(new, "runner:r1", params, :ok)
    assert params["running_job_ids"] == ["j1"]

    # Nothing was confirmed: the outbox outlived the connection and sends it all again.
    assert_push("runner:r1", "job:started", %{"job_id" => "j1"}, _ref, 5_000)
    assert_push("runner:r1", "job:event", %{"seq" => 1}, _ref, 5_000)
    assert Session.job_runner(session) == job_runner
  end

  test "a dropped connection is not the end of the session", %{session: session, client: client} do
    ref = Process.monitor(session)
    Process.exit(client, :kill)

    new = wait_new_connection(session, client)
    connect_and_assert_join(new, "runner:r1", _params, :ok)
    refute_received {:DOWN, ^ref, :process, _pid, _reason}
  end
end
