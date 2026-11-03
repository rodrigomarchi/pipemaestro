defmodule ClaudeControlPlaneRunner.JobRunnerTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneProtocol.Job
  alias ClaudeControlPlaneRunner.{Claude, JobRunner}

  @fake Path.expand("../support/fake_claude", __DIR__)

  @moduletag :tmp_dir

  defp start_runner(workdir, opts \\ []) do
    start_supervised!(
      {JobRunner,
       Keyword.merge([owner: self(), workdir: workdir, executable: {:ok, @fake}], opts)}
    )
  end

  defp job(id, prompt), do: %Job{id: id, prompt: prompt}

  defp collect_until_finished(id, acc \\ []) do
    receive do
      {:job_out, "job:finished", %{"job_id" => ^id} = payload} ->
        {Enum.reverse(acc), payload}

      {:job_out, event, %{"job_id" => ^id} = payload} ->
        collect_until_finished(id, [{event, payload} | acc])
    after
      10_000 -> flunk("job #{id} never finished; got #{inspect(Enum.reverse(acc))}")
    end
  end

  test "runs a job in the workdir and reports its events and outcome", %{tmp_dir: dir} do
    workdir = Path.join(dir, "workdir")
    runner = start_runner(workdir)

    JobRunner.enqueue(runner, job("j1", "diga oi"))

    {messages, finished} = collect_until_finished("j1")

    assert [{"job:started", %{"job_id" => "j1"}} | events] = messages
    assert Enum.map(events, fn {"job:event", e} -> e["seq"] end) == [1, 2, 3, 4, 5]

    assert Enum.map(events, fn {_, e} -> e["type"] end) ==
             ~w(system tool_use tool_result assistant_text result)

    assert {_, %{"data" => %{"cwd" => cwd}}} = hd(events)
    assert Path.basename(cwd) == "workdir"

    assert finished["status"] == "succeeded"
    assert finished["exit_code"] == 0
    assert finished["result"] =~ "fake-claude.txt"
    assert finished["cost_usd"] == 0.0042
    assert finished["duration_ms"] == 1234
    assert finished["num_turns"] == 2
    refute Map.has_key?(finished, "error")

    assert File.read!(Path.join(workdir, "fake-claude.txt")) == "diga oi\n"
    assert JobRunner.running_job_ids(runner) == []
  end

  test "a failing CLI fails the job with its stderr", %{tmp_dir: dir} do
    runner = start_runner(dir)
    JobRunner.enqueue(runner, job("j1", "quebre [falha]"))

    {_messages, finished} = collect_until_finished("j1")
    assert finished["status"] == "failed"
    assert finished["exit_code"] == 1
    assert finished["error"] =~ "código 1"
    assert finished["error"] =~ "falha simulada"
  end

  test "runs one job at a time, in order, ignoring a job queued twice", %{tmp_dir: dir} do
    runner = start_runner(dir)

    JobRunner.enqueue(runner, job("j1", "primeiro [lento]"))
    JobRunner.enqueue(runner, job("j2", "segundo"))
    JobRunner.enqueue(runner, job("j1", "primeiro [lento]"))

    assert_receive {:job_out, "job:started", %{"job_id" => "j1"}}
    assert JobRunner.running_job_ids(runner) == ["j1"]
    refute_received {:job_out, "job:started", %{"job_id" => "j2"}}

    JobRunner.cancel(runner, "j1")
    {_messages, finished} = collect_until_finished("j1")
    assert finished["status"] == "canceled"

    assert_receive {:job_out, "job:started", %{"job_id" => "j2"}}
    {_messages, finished} = collect_until_finished("j2")
    assert finished["status"] == "succeeded"
    refute_received {:job_out, "job:started", %{"job_id" => "j1"}}
  end

  test "canceling a waiting job drops it", %{tmp_dir: dir} do
    runner = start_runner(dir)

    JobRunner.enqueue(runner, job("j1", "primeiro [lento]"))
    JobRunner.enqueue(runner, job("j2", "segundo"))
    JobRunner.cancel(runner, "j2")
    JobRunner.cancel(runner, "j1")

    {_messages, finished} = collect_until_finished("j1")
    assert finished["status"] == "canceled"
    refute_receive {:job_out, "job:started", %{"job_id" => "j2"}}, 300
  end

  test "a CLI that ignores SIGTERM is killed", %{tmp_dir: dir} do
    stubborn = Path.join(dir, "stubborn")
    File.write!(stubborn, "#!/bin/sh\ntrap '' TERM\nsleep 30 &\nwait\nwait\n")
    File.chmod!(stubborn, 0o755)

    runner = start_runner(dir, executable: {:ok, stubborn}, kill_after: 100)
    JobRunner.enqueue(runner, job("j1", "x"))
    assert_receive {:job_out, "job:started", %{"job_id" => "j1"}}

    JobRunner.cancel(runner, "j1")
    {_messages, finished} = collect_until_finished("j1")
    assert finished["status"] == "canceled"
  end

  test "without the CLI the job fails at once", %{tmp_dir: dir} do
    runner = start_runner(dir, executable: {:error, :not_found})
    JobRunner.enqueue(runner, job("j1", "x"))

    {[{"job:started", _}], finished} = collect_until_finished("j1")
    assert finished["status"] == "failed"
    assert finished["error"] =~ "não foi encontrado"
  end

  describe "Claude" do
    test "argv runs headless, streaming JSON, with every permission" do
      argv = Claude.argv("diga oi")

      assert ["-p", "diga oi" | _] = argv
      assert "stream-json" in argv
      assert "--verbose" in argv
      assert "--dangerously-skip-permissions" in argv
      assert "--no-session-persistence" in argv
    end

    test "env unsets the nested-session markers" do
      assert {~c"CLAUDECODE", false} in Claude.env()
    end

    test "executable honors CLAUDE_BIN only when it exists" do
      previous = System.get_env("CLAUDE_BIN")

      try do
        System.put_env("CLAUDE_BIN", @fake)
        assert Claude.executable() == {:ok, @fake}

        System.put_env("CLAUDE_BIN", "/nao/existe")
        assert Claude.executable() == {:error, :not_found}
      after
        if previous,
          do: System.put_env("CLAUDE_BIN", previous),
          else: System.delete_env("CLAUDE_BIN")
      end
    end
  end
end
