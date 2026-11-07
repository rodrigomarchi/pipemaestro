defmodule PipeMaestroRunner.JobRunnerTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Job
  alias PipeMaestroRunner.{Claude, JobRunner}
  alias PipeMaestroRunner.Test.FilesServer

  @fake Path.expand("../support/fake_claude", __DIR__)

  @moduletag :tmp_dir

  defp start_runner(workdir, opts \\ []) do
    start_supervised!(
      {JobRunner,
       Keyword.merge([owner: self(), workdir: workdir, executable: {:ok, @fake}], opts)}
    )
  end

  defp git_repo!(repo) do
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    File.write!(Path.join(repo, "README.md"), "app")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
    git_commit = ~w(-c user.email=t@t -c user.name=t commit -q -m init)
    {_, 0} = System.cmd("git", ["-C", repo | git_commit])
    repo
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

  test "a job's git credential reaches git through the helper, and goes when the job ends",
       %{tmp_dir: dir} do
    workdir = Path.join(dir, "workdir")
    runner = start_runner(workdir)
    credential = %{"host" => "forge.test", "username" => "pipemaestro-bot", "password" => "tok"}

    JobRunner.enqueue(runner, %Job{id: "jc", prompt: "diga oi", git_credential: credential})
    {_messages, finished} = collect_until_finished("jc")

    assert finished["status"] == "succeeded"
    seen = File.read!(Path.join(workdir, "credencial-vista.txt"))
    assert seen =~ "username=pipemaestro-bot"
    assert seen =~ "password=tok"
    refute File.exists?(Path.join([workdir, "credentials", "jc"]))
  end

  test "a renewed credential rewrites the file of the running job", %{tmp_dir: dir} do
    workdir = Path.join(dir, "workdir")
    runner = start_runner(workdir)
    credential = %{"host" => "forge.test", "username" => "oauth2", "password" => "velho"}

    JobRunner.enqueue(runner, %Job{id: "jr", prompt: "espere [lento]", git_credential: credential})

    assert_receive {:job_out, "job:started", %{"job_id" => "jr"}}, 5_000
    path = Path.join([workdir, "credentials", "jr"])
    wait_until(fn -> File.exists?(path) end)

    JobRunner.renew_credential(runner, "jr", %{credential | "password" => "novo"})
    wait_until(fn -> File.read!(path) =~ "password=novo" end)

    JobRunner.cancel(runner, "jr")
    collect_until_finished("jr")
    refute File.exists?(path)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the condition never held")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end

  test "runs a job in the workdir and reports its events and outcome", %{tmp_dir: dir} do
    workdir = Path.join(dir, "workdir")
    runner = start_runner(workdir)

    JobRunner.enqueue(runner, job("j1", "diga oi"))

    {messages, finished} = collect_until_finished("j1")

    assert [{"job:started", %{"job_id" => "j1"}} | events] = messages
    assert Enum.map(events, fn {"job:event", e} -> e["seq"] end) == [1, 2, 3, 4, 5, 6]

    assert Enum.map(events, fn {_, e} -> e["type"] end) ==
             ~w(system thinking tool_use tool_result assistant_text result)

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

  test "the outcome carries what the run reported about itself, for auditing", %{tmp_dir: dir} do
    runner = start_runner(dir)
    JobRunner.enqueue(runner, job("j1", "diga oi"))
    {messages, finished} = collect_until_finished("j1")

    assert finished["session_id"] == "fake-session"
    assert finished["cli_version"] == "0.0.0-fake"
    assert finished["model"] == "fake-model"
    assert finished["stop_reason"] == "end_turn"
    assert finished["result_subtype"] == "success"
    assert finished["duration_api_ms"] == 900
    assert finished["ttft_ms"] == 300
    assert is_integer(finished["wall_ms"]) and finished["wall_ms"] >= 0

    assert finished["usage"] == %{
             "fresh_input" => 7,
             "cache_read" => 2_200,
             "cache_creation" => 200,
             "output" => 33,
             "thinking" => 0
           }

    assert %{"fake-model" => %{"cost_usd" => 0.0042}} = finished["model_usage"]
    assert finished["permission_denials"] == []

    assert %{
             "tools" => ["Bash", "Read", "Write"],
             "mcp_servers" => [%{"name" => "grafana", "status" => "connected"}],
             "permission_mode" => "bypassPermissions",
             "auth" => "none"
           } = finished["environment"]

    # The CLI's stderr is kept even when the job succeeds.
    assert finished["stderr"] =~ "aviso de exemplo"

    # A message split over two lines counts its tokens once.
    usages =
      for {"job:event", %{"type" => type, "data" => %{"usage" => usage}}} <- messages,
          type != "result",
          do: usage["message_id"]

    assert usages == ["msg_1", "msg_2"]
  end

  test "relays the CLI's OpenTelemetry for the job", %{tmp_dir: dir} do
    runner = start_runner(dir, telemetry: true)
    JobRunner.enqueue(runner, job("j1", "diga oi"))
    {messages, finished} = collect_until_finished("j1")
    assert finished["status"] == "succeeded"

    # The export (logs and metrics, one batch each) may come in before or
    # after the outcome.
    before = for {"job:telemetry", %{"records" => records}} <- messages, do: records

    later =
      for _batch <- 1..(2 - length(before))//1 do
        assert_receive {:job_out, "job:telemetry", %{"job_id" => "j1", "records" => records}},
                       5_000

        records
      end

    records = List.flatten(before ++ later)

    names = Enum.map(records, & &1["name"])
    assert "api_request" in names
    assert "tool_result" in names
    assert "metric:lines_of_code" in names
  end

  test "a stage runs in its task's worktree and reports its artifact and output", %{tmp_dir: dir} do
    root = Path.join(dir, "src")
    repo = git_repo!(Path.join(root, "app"))

    workdir = Path.join(dir, "workdir")
    runner = start_runner(workdir, root: root)

    stage = %Job{
      id: "j1",
      prompt: "etapa",
      directory: "app",
      worktree: %{"task_id" => "t1", "branch" => "cp/t1"},
      output_schema: %{"type" => "object"},
      artifact_path: ".control-plane/t1/01-a.md"
    }

    JobRunner.enqueue(runner, stage)
    {_messages, finished} = collect_until_finished("j1")

    worktree = Path.join([workdir, "worktrees", "t1"])
    assert finished["status"] == "succeeded"
    assert finished["workdir"] == worktree

    assert finished["structured_output"] == %{
             "status" => "ok",
             "resumo" => "Etapa concluída pelo fake_claude."
           }

    assert finished["artifact"] =~ "# Artefato do fake_claude"
    assert File.read!(Path.join(worktree, "fake-claude.txt")) == "etapa\n"
    refute File.exists?(Path.join(repo, "fake-claude.txt"))

    {branch, 0} = System.cmd("git", ["-C", worktree, "branch", "--show-current"])
    assert String.trim(branch) == "cp/t1"

    # The next stage of the same task reuses the worktree.
    JobRunner.enqueue(runner, %{stage | id: "j2", artifact_path: ".control-plane/t1/02-b.md"})
    {_messages, finished} = collect_until_finished("j2")
    assert finished["workdir"] == worktree
    assert File.exists?(Path.join(worktree, ".control-plane/t1/01-a.md"))

    # A directory that does not exist fails the job before the CLI runs.
    JobRunner.enqueue(runner, %Job{id: "j3", prompt: "x", directory: "nao-existe"})
    {[{"job:started", _}], finished} = collect_until_finished("j3")
    assert finished["error"] =~ "não existe"
  end

  test "an analysis runs in a disposable worktree, removed when it ends", %{tmp_dir: dir} do
    root = Path.join(dir, "src")
    repo = git_repo!(Path.join(root, "app"))
    File.mkdir_p!(Path.join([repo, "deps", "lib"]))
    File.mkdir_p!(Path.join(root, "notas"))

    workdir = Path.join(dir, "workdir")
    # A worktree left by a runner that stopped mid-analysis goes at start.
    File.mkdir_p!(Path.join([workdir, "scratch", "velho"]))
    runner = start_runner(workdir, root: root)
    refute File.exists?(Path.join([workdir, "scratch", "velho"]))

    job = %Job{
      id: "a1",
      prompt: "analise",
      directory: "app",
      scratch: true,
      output_schema: %{"type" => "object"}
    }

    JobRunner.enqueue(runner, job)
    {_messages, finished} = collect_until_finished("a1")

    scratch = Path.join([workdir, "scratch", "a1"])
    assert finished["status"] == "succeeded"
    assert finished["workdir"] == scratch
    assert finished["setup"]["copied"] == ["deps"]
    refute Map.has_key?(finished, "changes")
    # The agent's file never reaches the directory, and the worktree goes.
    refute File.exists?(Path.join(repo, "fake-claude.txt"))
    assert eventually(fn -> not File.exists?(scratch) end)
    {list, 0} = System.cmd("git", ["-C", repo, "worktree", "list"])
    refute list =~ "scratch"
    {status, 0} = System.cmd("git", ["-C", repo, "status", "--porcelain"])
    assert status == ""

    # A directory without git cannot be analysed.
    JobRunner.enqueue(runner, %Job{id: "a2", prompt: "x", directory: "notas", scratch: true})
    {[{"job:started", _}], finished} = collect_until_finished("a2")
    assert finished["status"] == "failed"
    assert finished["error"] =~ "repositório git"
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  test "relays what the agent is writing, apart from the events", %{tmp_dir: dir} do
    runner = start_runner(dir)
    JobRunner.enqueue(runner, job("j1", "responda [digitando]"))

    assert_receive {:job_live, "job:delta", %{"job_id" => "j1", "text" => "Pronto: "}}, 5_000
    assert_receive {:job_live, "job:delta", %{"text" => "Pronto: gravei o prompt "}}, 5_000

    assert_receive {:job_live, "job:delta",
                    %{"text" => "Pronto: gravei o prompt em fake-claude.txt."}},
                   5_000

    {messages, finished} = collect_until_finished("j1")
    assert finished["status"] == "succeeded"
    # The deltas are not events: the sequence is the usual one.
    assert Enum.count(messages, &match?({"job:event", _}, &1)) == 6
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

  describe "the job's files" do
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
         )

    setup %{tmp_dir: dir} do
      server = FilesServer.start()
      %{server: server, workdir: Path.join(dir, "workdir")}
    end

    defp start_uploading(ctx, opts \\ []) do
      start_runner(
        ctx.workdir,
        [
          files: %{url: ctx.server.url, token: "cpr_teste"},
          files_req_options: [retry_delay: fn _attempt -> 0 end]
        ] ++ opts
      )
    end

    defp uploads(server), do: Enum.map(FilesServer.requests(server), &{&1.job_id, &1.path})

    test "uploads what the agent left in CP_FILES_DIR, skips symlinks and drops the folder",
         ctx do
      runner = start_uploading(ctx)

      JobRunner.enqueue(runner, job("j1", "tire as telas [arquivos]"))
      {_messages, finished} = collect_until_finished("j1")

      assert finished["status"] == "succeeded"
      refute Map.has_key?(finished, "files_failed")
      assert uploads(ctx.server) == [{"j1", "a.png"}, {"j1", "dados/r.csv"}]

      [png, csv] = FilesServer.requests(ctx.server)
      assert png.method == "PUT"
      assert png.authorization == "Bearer cpr_teste"
      assert png.content_type =~ "application/octet-stream"
      assert png.body == @png
      assert csv.body == "tela,ok\nlogin,sim\n"

      wait_until(fn -> not File.exists?(Path.join([ctx.workdir, "files", "j1"])) end)
    end

    test "the folder is outside the job's directory, and a fresh one per job", ctx do
      runner = start_uploading(ctx)

      JobRunner.enqueue(runner, job("j1", "[arquivos]"))
      collect_until_finished("j1")
      JobRunner.enqueue(runner, job("j2", "nada"))
      collect_until_finished("j2")

      assert uploads(ctx.server) == [{"j1", "a.png"}, {"j1", "dados/r.csv"}]
      refute File.exists?(Path.join(ctx.workdir, "a.png"))
    end

    test "a failed job also uploads its files", ctx do
      runner = start_uploading(ctx)

      JobRunner.enqueue(runner, job("j1", "[arquivos] [falha]"))
      {_messages, finished} = collect_until_finished("j1")

      assert finished["status"] == "failed"
      assert uploads(ctx.server) == [{"j1", "a.png"}, {"j1", "dados/r.csv"}]
    end

    test "a control plane without the endpoint: tried once, counted, the job ends as it would",
         ctx do
      FilesServer.respond(ctx.server, 404)
      runner = start_uploading(ctx)

      JobRunner.enqueue(runner, job("j1", "[arquivos]"))
      {_messages, finished} = collect_until_finished("j1")

      assert finished["status"] == "succeeded"
      assert finished["files_failed"] == 2
      assert uploads(ctx.server) == [{"j1", "a.png"}, {"j1", "dados/r.csv"}]
    end

    test "a server error is tried again, then counted", ctx do
      FilesServer.respond(ctx.server, 500)
      runner = start_uploading(ctx)

      JobRunner.enqueue(runner, job("j1", "[arquivos]"))
      {_messages, finished} = collect_until_finished("j1")

      assert finished["status"] == "succeeded"
      assert finished["files_failed"] == 2

      tries = Enum.frequencies(uploads(ctx.server))
      assert tries[{"j1", "a.png"}] > 1
      assert tries[{"j1", "dados/r.csv"}] > 1
    end

    test "without an upload configured, the agent gets no folder and nothing is sent", ctx do
      runner = start_runner(ctx.workdir)

      JobRunner.enqueue(runner, job("j1", "[arquivos]"))
      {_messages, finished} = collect_until_finished("j1")

      assert finished["status"] == "succeeded"
      refute Map.has_key?(finished, "files_failed")
      assert FilesServer.requests(ctx.server) == []
      refute File.exists?(Path.join([ctx.workdir, "files", "j1"]))
    end

    test "leftovers of an earlier run are cleared when the runner starts", ctx do
      stale = Path.join([ctx.workdir, "files", "velho"])
      File.mkdir_p!(stale)
      File.write!(Path.join(stale, "x.txt"), "x")

      start_uploading(ctx)
      refute File.exists?(stale)
    end

    test "in a task's worktree nothing reaches git, and the checks still pass",
         %{tmp_dir: dir} =
           ctx do
      root = Path.join(dir, "src")
      git_repo!(Path.join(root, "app"))
      runner = start_uploading(ctx, root: root)
      worktree = Path.join([ctx.workdir, "worktrees", "t1"])

      stage = %Job{
        id: "j1",
        prompt: "etapa [arquivos]",
        directory: "app",
        worktree: %{"task_id" => "t1", "branch" => "cp/t1"},
        output_schema: %{"type" => "object"},
        artifact_path: ".control-plane/t1/01-a.md",
        checks: [
          %{"id" => "clean"},
          %{"id" => "artifact_committed", "path" => ".control-plane/t1/01-a.md"}
        ]
      }

      JobRunner.enqueue(runner, stage)
      {_messages, finished} = collect_until_finished("j1")

      assert finished["status"] == "succeeded"

      assert [
               %{"id" => "clean", "passed" => true},
               %{"id" => "artifact_committed", "passed" => true}
             ] =
               finished["gates"]

      {status, 0} = System.cmd("git", ["-C", worktree, "status", "--porcelain"])
      assert status == ""
      {tracked, 0} = System.cmd("git", ["-C", worktree, "ls-files"])
      refute tracked =~ "a.png"
      refute tracked =~ "r.csv"
      assert uploads(ctx.server) == [{"j1", "a.png"}, {"j1", "dados/r.csv"}]
    end
  end

  describe "worktree setup" do
    setup %{tmp_dir: dir} do
      root = Path.join(dir, "src")
      repo = git_repo!(Path.join(root, "app"))
      File.mkdir_p!(Path.join([repo, "deps", "jason"]))
      %{root: root, workdir: Path.join(dir, "workdir")}
    end

    defp stage(id, task, setup) do
      %Job{
        id: id,
        prompt: "etapa",
        directory: "app",
        worktree: %{"task_id" => task, "branch" => "cp/" <> task},
        setup: setup
      }
    end

    test "a new worktree gets the dependencies and the setup command, once", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)
      worktree = Path.join([ctx.workdir, "worktrees", "t1"])

      JobRunner.enqueue(runner, stage("j1", "t1", %{"command" => "echo pronto > setup.txt"}))
      {_messages, finished} = collect_until_finished("j1")

      assert finished["status"] == "succeeded"
      assert %{"copied" => ["deps"], "exit_code" => 0, "duration_ms" => _} = finished["setup"]
      assert File.dir?(Path.join([worktree, "deps", "jason"]))
      assert File.read!(Path.join(worktree, "setup.txt")) == "pronto\n"

      JobRunner.enqueue(runner, stage("j2", "t1", %{"command" => "echo de novo > setup.txt"}))
      {_messages, finished} = collect_until_finished("j2")
      refute Map.has_key?(finished, "setup")
      assert File.read!(Path.join(worktree, "setup.txt")) == "pronto\n"
    end

    test "reports what each stage changed, and what the task changed so far", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)
      first = %{stage("j1", "t1", nil) | artifact_path: ".control-plane/t1/01-a.md"}

      JobRunner.enqueue(runner, first)
      {_messages, finished} = collect_until_finished("j1")

      assert %{"files" => files, "patch" => patch, "task_files" => task_files} =
               finished["changes"]

      assert Enum.map(files, & &1["path"]) == [".control-plane/t1/01-a.md", "fake-claude.txt"]
      assert patch =~ "+etapa"
      assert task_files == files

      second = %{first | id: "j2", prompt: "outra", artifact_path: ".control-plane/t1/02-b.md"}
      JobRunner.enqueue(runner, second)
      {_messages, finished} = collect_until_finished("j2")

      assert Enum.map(finished["changes"]["files"], & &1["path"]) ==
               [".control-plane/t1/02-b.md", "fake-claude.txt"]

      assert Enum.map(finished["changes"]["task_files"], & &1["path"]) ==
               [".control-plane/t1/01-a.md", ".control-plane/t1/02-b.md", "fake-claude.txt"]
    end

    test "runs the gates after the agent and reports each against its expectation", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)

      gates = [
        %{"command" => "test -f fake-claude.txt", "expect" => "pass"},
        %{"command" => "echo quebrou; exit 3", "expect" => "fail"},
        %{"command" => "echo ainda falha >&2; exit 1", "expect" => "pass"}
      ]

      JobRunner.enqueue(runner, %{stage("j1", "t1", nil) | gates: gates})
      {_messages, finished} = collect_until_finished("j1")

      assert finished["status"] == "succeeded"

      assert [
               %{"expect" => "pass", "exit_code" => 0, "passed" => true},
               %{"expect" => "fail", "exit_code" => 3, "passed" => true, "output" => "quebrou\n"},
               %{"expect" => "pass", "exit_code" => 1, "passed" => false, "output" => out}
             ] = finished["gates"]

      assert out =~ "ainda falha"
      assert is_integer(hd(finished["gates"])["duration_ms"])
    end

    test "delivers a stage that passed: the agent's commit, after the platform's checks", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)
      worktree = Path.join([ctx.workdir, "worktrees", "t1"])

      stage = %{
        stage("j1", "t1", nil)
        | output_schema: %{"type" => "object"},
          delivery: %{},
          checks: [%{"id" => "branch", "branch" => "cp/t1"}, %{"id" => "clean"}],
          gates: [%{"command" => "true", "expect" => "pass"}]
      }

      JobRunner.enqueue(runner, stage)
      {_messages, finished} = collect_until_finished("j1")

      {head, 0} = System.cmd("git", ["-C", worktree, "rev-parse", "HEAD"])
      assert %{"commit" => sha, "pushed" => false} = finished["delivery"]
      assert sha == String.trim(head)
      {subject, 0} = System.cmd("git", ["-C", worktree, "log", "-1", "--format=%s"])
      assert String.trim(subject) == "fake_claude: etapa"

      assert [
               %{"id" => "branch", "platform" => true, "passed" => true},
               %{"id" => "clean", "passed" => true},
               %{"command" => "true", "passed" => true}
             ] = finished["gates"]

      # Something left uncommitted: the check fails, the gates do not run and
      # nothing is delivered.
      dirty = %{stage | id: "j2", prompt: "x [sujo]"}
      JobRunner.enqueue(runner, dirty)
      {_messages, finished} = collect_until_finished("j2")
      refute Map.has_key?(finished, "delivery")

      assert [
               %{"id" => "branch", "passed" => true},
               %{"id" => "clean", "passed" => false} = clean
             ] =
               finished["gates"]

      assert clean["message"] =~ "`sujo.txt`"

      # A stage the agent blocked is not delivered.
      blocked = %{stage | id: "j3", prompt: "x [bloqueio]"}
      JobRunner.enqueue(runner, blocked)
      {_messages, finished} = collect_until_finished("j3")
      refute Map.has_key?(finished, "delivery")
    end

    test "what the setup command created is the platform's, not left by the agent", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)

      stage = %{
        stage("j1", "t1", %{"command" => "echo pronto > setup.txt"})
        | checks: [%{"id" => "clean"}]
      }

      JobRunner.enqueue(runner, stage)
      {_messages, finished} = collect_until_finished("j1")
      assert [%{"id" => "clean", "passed" => true}] = finished["gates"]

      # And in the stages after, which read it from the task's base.
      JobRunner.enqueue(runner, %{stage | id: "j2", setup: nil})
      {_messages, finished} = collect_until_finished("j2")
      assert [%{"id" => "clean", "passed" => true}] = finished["gates"]
    end

    test "before the agent: the earlier artifacts come back and the sync is told", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)
      worktree = Path.join([ctx.workdir, "worktrees", "t1"])

      stage = %{
        stage("j1", "t1", nil)
        | sync: true,
          artifacts: [%{"path" => ".control-plane/t1/01-plano.md", "content" => "# Plano"}]
      }

      JobRunner.enqueue(runner, stage)
      {_messages, _finished} = collect_until_finished("j1")
      assert File.read!(Path.join(worktree, ".control-plane/t1/01-plano.md")) == "# Plano"

      # On another branch, the agent is told so in its prompt.
      {_, 0} = System.cmd("git", ["-C", worktree, "checkout", "-q", "-b", "outra"])
      JobRunner.enqueue(runner, %{stage | id: "j2"})
      {_messages, _finished} = collect_until_finished("j2")
      assert File.read!(Path.join(worktree, "fake-claude.txt")) =~ "Estado do repositório"
      assert File.read!(Path.join(worktree, "fake-claude.txt")) =~ "na branch `outra`"
    end

    test "a stage the agent blocks with questions reports them", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)

      asking = %{
        stage("j1", "t1", nil)
        | prompt: "x [perguntas]",
          output_schema: %{"type" => "object"}
      }

      JobRunner.enqueue(runner, asking)
      {_messages, finished} = collect_until_finished("j1")

      assert %{"status" => "bloqueado", "perguntas" => [single, multiple]} =
               finished["structured_output"]

      assert single["multipla"] == false
      assert Enum.any?(single["opcoes"], &(&1["recomendada"] and &1["preview"] =~ "```"))
      assert multiple["multipla"] == true
    end

    test "a failed agent run skips the gates", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)
      gates = [%{"command" => "touch gate-rodou", "expect" => "pass"}]

      JobRunner.enqueue(runner, %{stage("j1", "t1", nil) | prompt: "x [falha]", gates: gates})
      {_messages, finished} = collect_until_finished("j1")

      assert finished["status"] == "failed"
      refute Map.has_key?(finished, "gates")
      refute File.exists?(Path.join([ctx.workdir, "worktrees", "t1", "gate-rodou"]))
    end

    test "a job on its own reports no changes", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)
      JobRunner.enqueue(runner, job("j1", "avulso"))
      {_messages, finished} = collect_until_finished("j1")
      refute Map.has_key?(finished, "changes")
    end

    test "a failing setup fails the job and drops the worktree for the next try", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)
      worktree = Path.join([ctx.workdir, "worktrees", "t1"])

      JobRunner.enqueue(runner, stage("j1", "t1", %{"command" => "echo sem rede; exit 2"}))
      {[{"job:started", _}], finished} = collect_until_finished("j1")

      assert finished["status"] == "failed"
      assert finished["error"] =~ "setup"
      assert finished["error"] =~ "sem rede"
      assert finished["setup"]["exit_code"] == 2
      refute File.exists?(worktree)

      JobRunner.enqueue(runner, stage("j2", "t1", %{"command" => "true"}))
      {_messages, finished} = collect_until_finished("j2")
      assert finished["status"] == "succeeded"
      assert finished["setup"]["exit_code"] == 0
    end

    test "canceling during the setup stops it", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root, kill_after: 100)

      JobRunner.enqueue(runner, stage("j1", "t1", %{"command" => "sleep 30"}))
      assert_receive {:job_out, "job:started", %{"job_id" => "j1"}}
      assert JobRunner.running_job_ids(runner) == ["j1"]
      Process.sleep(200)

      JobRunner.cancel(runner, "j1")
      {_messages, finished} = collect_until_finished("j1")
      assert finished["status"] == "canceled"
    end
  end

  describe "removing a worktree" do
    setup %{tmp_dir: dir} do
      root = Path.join(dir, "src")
      repo = git_repo!(Path.join(root, "app"))
      %{root: root, repo: repo, workdir: Path.join(dir, "workdir")}
    end

    test "removes a task's worktree and keeps its branch", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)
      JobRunner.enqueue(runner, stage("j1", "t1", nil))
      collect_until_finished("j1")
      worktree = Path.join([ctx.workdir, "worktrees", "t1"])
      assert File.dir?(worktree)

      JobRunner.remove_worktree(runner, "t1", "app")
      assert_receive {:job_out, "worktree:removed", %{"task_id" => "t1"} = reply}, 5_000
      refute Map.has_key?(reply, "error")
      refute File.exists?(worktree)

      {branches, 0} = System.cmd("git", ["-C", ctx.repo, "branch", "--list", "cp/t1"])
      assert branches =~ "cp/t1"

      # Removing again is fine.
      JobRunner.remove_worktree(runner, "t1", "app")
      assert_receive {:job_out, "worktree:removed", %{"task_id" => "t1"} = reply}, 5_000
      refute Map.has_key?(reply, "error")
    end

    test "refuses while the task has a job running or waiting", ctx do
      runner = start_runner(ctx.workdir, root: ctx.root)
      JobRunner.enqueue(runner, %{stage("j1", "t1", nil) | prompt: "devagar [lento]"})
      assert_receive {:job_out, "job:started", %{"job_id" => "j1"}}

      JobRunner.remove_worktree(runner, "t1", "app")
      assert_receive {:job_out, "worktree:removed", %{"task_id" => "t1", "error" => error}}
      assert error =~ "em execução"

      JobRunner.cancel(runner, "j1")
      collect_until_finished("j1")
    end
  end

  test "a job that runs past its time limit is stopped and fails", %{tmp_dir: dir} do
    runner = start_runner(dir, kill_after: 100)
    JobRunner.enqueue(runner, %Job{id: "j1", prompt: "devagar [lento]", timeout_ms: 300})

    {_messages, finished} = collect_until_finished("j1")
    assert finished["status"] == "failed"
    assert finished["error"] =~ "tempo máximo"
  end

  test "a stage in a directory without git reports the files it touched", %{tmp_dir: dir} do
    root = Path.join(dir, "src")
    File.mkdir_p!(Path.join(root, "notas"))
    runner = start_runner(Path.join(dir, "workdir"), root: root)

    JobRunner.enqueue(runner, %Job{id: "j1", prompt: "anote", directory: "notas"})
    {_messages, finished} = collect_until_finished("j1")

    assert [%{"path" => "fake-claude.txt", "status" => "new"}] = finished["changes"]["files"]
  end

  describe "parallel jobs" do
    setup %{tmp_dir: dir} do
      root = Path.join(dir, "src")
      for name <- ~w(a b c), do: File.mkdir_p!(Path.join(root, name))
      %{root: root}
    end

    defp in_dir(id, prompt, directory), do: %Job{id: id, prompt: prompt, directory: directory}

    test "runs jobs in different directories at once, up to the capacity", %{
      tmp_dir: dir,
      root: root
    } do
      runner = start_runner(Path.join(dir, "workdir"), root: root, capacity: 2)

      JobRunner.enqueue(runner, in_dir("j1", "um [lento]", "a"))
      JobRunner.enqueue(runner, in_dir("j2", "dois [lento]", "b"))
      JobRunner.enqueue(runner, in_dir("j3", "tres", "c"))

      assert_receive {:job_out, "job:started", %{"job_id" => "j1"}}
      assert_receive {:job_out, "job:started", %{"job_id" => "j2"}}
      refute_receive {:job_out, "job:started", %{"job_id" => "j3"}}, 200
      assert Enum.sort(JobRunner.running_job_ids(runner)) == ["j1", "j2"]

      JobRunner.cancel(runner, "j1")
      {_messages, finished} = collect_until_finished("j1")
      assert finished["status"] == "canceled"

      {_messages, finished} = collect_until_finished("j3")
      assert finished["status"] == "succeeded"

      JobRunner.cancel(runner, "j2")
      {_messages, finished} = collect_until_finished("j2")
      assert finished["status"] == "canceled"
    end

    test "jobs sharing a place wait for each other; others go ahead", %{
      tmp_dir: dir,
      root: root
    } do
      runner = start_runner(Path.join(dir, "workdir"), root: root, capacity: 4)

      JobRunner.enqueue(runner, in_dir("j1", "um [lento]", "a"))
      JobRunner.enqueue(runner, in_dir("j2", "dois", "a"))
      JobRunner.enqueue(runner, job("j3", "avulso [lento]"))
      JobRunner.enqueue(runner, job("j4", "outro avulso"))

      assert_receive {:job_out, "job:started", %{"job_id" => "j1"}}
      assert_receive {:job_out, "job:started", %{"job_id" => "j3"}}
      refute_receive {:job_out, "job:started", %{"job_id" => _}}, 200

      JobRunner.cancel(runner, "j1")
      {_messages, _finished} = collect_until_finished("j1")
      {_messages, finished} = collect_until_finished("j2")
      assert finished["status"] == "succeeded"

      JobRunner.cancel(runner, "j3")
      {_messages, _finished} = collect_until_finished("j3")
      {_messages, finished} = collect_until_finished("j4")
      assert finished["status"] == "succeeded"
    end

    test "stages of different tasks in one repository run at once", %{tmp_dir: dir} do
      root = Path.join(dir, "repos")
      repo = git_repo!(Path.join(root, "app"))
      assert File.dir?(repo)
      runner = start_runner(Path.join(dir, "workdir"), root: root, capacity: 2)

      stage = fn id, task ->
        %Job{
          id: id,
          prompt: "etapa [lento]",
          directory: "app",
          worktree: %{"task_id" => task, "branch" => "cp/" <> task}
        }
      end

      JobRunner.enqueue(runner, stage.("j1", "t1"))
      JobRunner.enqueue(runner, stage.("j2", "t2"))
      JobRunner.enqueue(runner, stage.("j3", "t1"))

      assert_receive {:job_out, "job:started", %{"job_id" => "j1"}}, 5_000
      assert_receive {:job_out, "job:started", %{"job_id" => "j2"}}, 5_000
      refute_receive {:job_out, "job:started", %{"job_id" => "j3"}}, 200

      for id <- ~w(j3 j1 j2), do: JobRunner.cancel(runner, id)
      for id <- ~w(j1 j2), do: collect_until_finished(id)
    end

    test "stages of one task marked parallel run at once in its worktree", %{tmp_dir: dir} do
      root = Path.join(dir, "repos")
      git_repo!(Path.join(root, "app"))
      runner = start_runner(Path.join(dir, "workdir"), root: root, capacity: 3)

      stage = fn id ->
        %Job{
          id: id,
          prompt: "auditoria [lento]",
          directory: "app",
          worktree: %{"task_id" => "t1", "branch" => "cp/t1"},
          parallel: true
        }
      end

      # The worktree exists before the group (the first stage cannot be in one).
      JobRunner.enqueue(runner, %{stage.("j0") | prompt: "implementar", parallel: nil})
      collect_until_finished("j0")

      JobRunner.enqueue(runner, stage.("j1"))
      JobRunner.enqueue(runner, stage.("j2"))
      assert_receive {:job_out, "job:started", %{"job_id" => "j1"}}, 5_000
      assert_receive {:job_out, "job:started", %{"job_id" => "j2"}}, 5_000

      # The task is busy: its worktree cannot go while they run.
      JobRunner.remove_worktree(runner, "t1", "app")
      assert_receive {:job_out, "worktree:removed", %{"error" => _}}, 5_000

      for id <- ~w(j1 j2), do: JobRunner.cancel(runner, id)
      for id <- ~w(j1 j2), do: collect_until_finished(id)
    end
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

  describe "continuing the previous stage's session" do
    defp resume_job(id, prompt, dir, fields) do
      {:ok, job} =
        Job.from_map(
          Map.merge(
            %{
              "id" => id,
              "prompt" => prompt,
              "env" => %{"FAKE_CLAUDE_ARGS_FILE" => Path.join(dir, "#{id}-args.txt")}
            },
            fields
          )
        )

      job
    end

    defp args_seen(dir, id),
      do: dir |> Path.join("#{id}-args.txt") |> File.read!() |> String.split("\n", trim: true)

    test "a job that resumes a session forks it and says so", %{tmp_dir: dir} do
      runner = start_runner(Path.join(dir, "workdir"))

      JobRunner.enqueue(
        runner,
        resume_job("jr", "continue", dir, %{"resume_session_id" => "s-1"})
      )

      {_messages, finished} = collect_until_finished("jr")
      assert finished["status"] == "succeeded"
      assert finished["session_resumed"] == true

      args = args_seen(dir, "jr")
      assert ["--resume", "s-1", "--fork-session"] in Enum.chunk_every(args, 3, 1)
      refute "--no-session-persistence" in args
    end

    test "a session the CLI does not have: the job runs again fresh, once", %{tmp_dir: dir} do
      runner = start_runner(Path.join(dir, "workdir"))

      JobRunner.enqueue(
        runner,
        resume_job("ja", "continue", dir, %{
          "resume_session_id" => "ausente-1",
          "persist_session" => true
        })
      )

      {messages, finished} = collect_until_finished("ja")
      assert finished["status"] == "succeeded"
      assert finished["exit_code"] == 0
      assert finished["session_resumed"] == false
      assert finished["session_id"] == "fake-session"

      events = for {"job:event", e} <- messages, do: e["seq"]
      assert events == Enum.to_list(1..length(events))

      args = args_seen(dir, "ja")
      refute "--resume" in args
      refute "--no-session-persistence" in args
    end

    test "a run that fails after resuming is not run again", %{tmp_dir: dir} do
      runner = start_runner(Path.join(dir, "workdir"))

      JobRunner.enqueue(
        runner,
        resume_job("jf", "quebre [falha]", dir, %{"resume_session_id" => "s-1"})
      )

      {_messages, finished} = collect_until_finished("jf")
      assert finished["status"] == "failed"
      assert finished["session_resumed"] == true
      assert "--resume" in args_seen(dir, "jf")
    end

    test "a job that asks for no resume says nothing about it", %{tmp_dir: dir} do
      runner = start_runner(Path.join(dir, "workdir"))
      JobRunner.enqueue(runner, resume_job("jn", "diga oi", dir, %{}))

      {_messages, finished} = collect_until_finished("jn")
      refute Map.has_key?(finished, "session_resumed")
      assert "--no-session-persistence" in args_seen(dir, "jn")
    end
  end

  describe "Claude" do
    test "argv runs headless, streaming JSON, with every permission" do
      argv = Claude.argv(job("j", "diga oi"))

      assert ["-p", "diga oi" | _] = argv
      assert "stream-json" in argv
      assert "--verbose" in argv
      assert "--dangerously-skip-permissions" in argv
      assert "--no-session-persistence" in argv
      assert "--include-partial-messages" in argv
      refute "--json-schema" in argv
    end

    test "argv adds the stage's schema, model and budget" do
      argv =
        Claude.argv(%Job{
          id: "j",
          prompt: "p",
          output_schema: %{"type" => "object"},
          model: "haiku",
          max_budget_usd: 0.5
        })

      assert [
               "--json-schema",
               ~s({"type":"object"}),
               "--model",
               "haiku",
               "--max-budget-usd",
               "0.5"
             ] =
               Enum.drop(argv, 8)
    end

    test "argv keeps the session for the next stage, or resumes the previous one" do
      {:ok, keep} = Job.from_map(%{"id" => "j", "prompt" => "p", "persist_session" => true})
      argv = Claude.argv(keep)
      refute "--no-session-persistence" in argv
      refute "--resume" in argv

      {:ok, resume} = Job.from_map(%{"id" => "j", "prompt" => "p", "resume_session_id" => "s-1"})
      argv = Claude.argv(resume)
      refute "--no-session-persistence" in argv
      assert ["--resume", "s-1", "--fork-session"] in Enum.chunk_every(argv, 3, 1)
    end

    test "argv has no budget when the job carries none" do
      {:ok, job} =
        Job.from_map(%{
          "id" => "j",
          "prompt" => "p",
          "output_schema" => %{"type" => "object"},
          "timeout_ms" => 60_000
        })

      refute "--max-budget-usd" in Claude.argv(job)
    end

    test "argv gives the pipeline's context: system prompt, MCP servers and agents" do
      argv =
        Claude.argv(%Job{
          id: "j",
          prompt: "p",
          system_prompt: "Responda em português.",
          mcp_config: %{"mcpServers" => %{}},
          agents: %{"revisor" => %{"description" => "d", "prompt" => "p"}},
          agent: "revisor"
        })

      pairs = Enum.chunk_every(argv, 2, 1)
      assert ["--append-system-prompt", "Responda em português."] in pairs
      assert ["--mcp-config", ~s({"mcpServers":{}})] in pairs
      assert ["--agents", ~s({"revisor":{"description":"d","prompt":"p"}})] in pairs
      assert ["--agent", "revisor"] in pairs
    end

    test "argv never narrows what the agent may do, whatever the job carries" do
      {:ok, job} =
        Job.from_map(%{
          "id" => "j",
          "prompt" => "p",
          "model" => "sonnet",
          "agent" => "revisor",
          "permissions" => %{"profile" => "leitura", "allow" => ["Bash(git log:*)"]}
        })

      argv = Claude.argv(job)
      assert "--dangerously-skip-permissions" in argv

      for flag <- ~w(--permission-mode --allowedTools --disallowedTools --permission-prompts),
          do: refute(flag in argv)
    end

    test "env passes the workspace's secrets to the CLI" do
      env = Claude.env(%Job{id: "j", prompt: "p", env: %{"GRAFANA_TOKEN" => "s3"}})
      assert {~c"GRAFANA_TOKEN", ~c"s3"} in env
    end

    test "env points the CLI's OpenTelemetry at the runner, naming the job" do
      env = Claude.env(job("j9", "p"), "http://127.0.0.1:4318")
      assert {~c"CLAUDE_CODE_ENABLE_TELEMETRY", ~c"1"} in env
      assert {~c"OTEL_EXPORTER_OTLP_PROTOCOL", ~c"http/json"} in env
      assert {~c"OTEL_EXPORTER_OTLP_ENDPOINT", ~c"http://127.0.0.1:4318"} in env
      assert {~c"OTEL_LOGS_EXPORTER", ~c"otlp"} in env
      assert {~c"OTEL_METRICS_EXPORTER", ~c"otlp"} in env
      assert {~c"OTEL_RESOURCE_ATTRIBUTES", ~c"cp.job_id=j9"} in env
      # Prompts and answers stay out of the telemetry: the events carry them.
      assert {~c"OTEL_LOG_USER_PROMPTS", false} in env

      refute Enum.any?(
               Claude.env(job("j", "p")),
               &match?({~c"CLAUDE_CODE_ENABLE_TELEMETRY", _}, &1)
             )
    end

    test "env unsets the nested-session markers and gives the artifact path" do
      env = Claude.env(%Job{id: "j", prompt: "p", artifact_path: ".cp/a.md"})
      assert {~c"CLAUDECODE", false} in env
      assert {~c"__BURRITO", false} in env
      assert {~c"CP_ARTIFACT_PATH", ~c".cp/a.md"} in env
      assert {~c"CP_ARTIFACT_PATH", false} in Claude.env(job("j", "p"))
    end

    test "env gives the job's files folder, absolute, only when there is one" do
      env = Claude.env(job("j", "p"), nil, "/w/files/j")
      assert {~c"CP_FILES_DIR", ~c"/w/files/j"} in env
      assert {~c"CP_FILES_DIR", false} in Claude.env(job("j", "p"))
      assert {~c"CP_FILES_DIR", false} in Claude.env(job("j", "p"), nil, nil)
    end

    test "the runner's own API key goes to the CLI, and the agent says how it signs in" do
      previous = System.get_env("RUNNER_ANTHROPIC_API_KEY")

      try do
        System.delete_env("RUNNER_ANTHROPIC_API_KEY")
        refute Enum.any?(Claude.env(job("j", "p")), &match?({~c"ANTHROPIC_API_KEY", _}, &1))
        assert %{"auth" => "login", "cli_version" => "0.0.0-fake"} = Claude.agent({:ok, @fake})
        assert %{"auth" => "login", "cli_version" => nil} = Claude.agent({:error, :not_found})

        System.put_env("RUNNER_ANTHROPIC_API_KEY", "sk-teste")
        assert {~c"ANTHROPIC_API_KEY", ~c"sk-teste"} in Claude.env(job("j", "p"))
        assert %{"auth" => "api_key"} = Claude.agent({:ok, @fake})
      after
        if previous,
          do: System.put_env("RUNNER_ANTHROPIC_API_KEY", previous),
          else: System.delete_env("RUNNER_ANTHROPIC_API_KEY")
      end
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
