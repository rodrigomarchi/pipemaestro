defmodule PipeMaestroRunner.ClaudeSessionsTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.ClaudeSessions

  @moduletag :tmp_dir

  @session "2f517ed4-46fa-4ab0-a237-840babadcd65"
  @other_session "607a4c45-7c11-44c7-a5d7-ef9ecefd17a3"

  describe "dir_name/1" do
    test "every character outside [A-Za-z0-9] becomes a dash" do
      assert ClaudeSessions.dir_name("/a/b.c_d e/f-g") == "-a-b-c-d-e-f-g"

      assert ClaudeSessions.dir_name("/Users/rodrigo/.config/pipemaestro/workdir/worktrees/44ac") ==
               "-Users-rodrigo--config-pipemaestro-workdir-worktrees-44ac"
    end

    test "counts UTF-16 units, as the CLI does: a character outside the BMP is two dashes" do
      assert ClaudeSessions.dir_name("/x/é😀") == "-x----"
    end

    # Expected values computed with the CLI's own function (2.1.319): the
    # first 200 characters, a dash and the base-36 Java-style hash of the path.
    test "a name over 200 characters is cut and gets the path's hash" do
      long = "/srv/" <> String.duplicate("x", 250)

      assert ClaudeSessions.dir_name(long) ==
               "-srv-" <> String.duplicate("x", 195) <> "-k2t98n"

      accented = "/srv/ação/" <> String.duplicate("y", 200) <> "/é 😀"

      assert ClaudeSessions.dir_name(accented) ==
               "-srv-a--o-" <> String.duplicate("y", 190) <> "-9ggowd"
    end
  end

  describe "real_path/1 and task_cwd/2" do
    test "resolves symlinks, as the CLI's cwd does", %{tmp_dir: dir} do
      real = Path.join(dir, "real")
      File.mkdir_p!(Path.join(real, "worktrees/t1"))
      link = Path.join(dir, "link")
      File.ln_s!(real, link)

      resolved = ClaudeSessions.real_path(Path.join(link, "worktrees/t1"))
      assert resolved == ClaudeSessions.real_path(Path.join(real, "worktrees/t1"))
      refute resolved =~ "/link/"
      assert String.ends_with?(resolved, "/real/worktrees/t1")
    end

    test "a link to the system's temporary directory resolves like it (/tmp on macOS)",
         %{tmp_dir: dir} do
      link = Path.join(dir, "tmp-link")
      File.ln_s!(System.tmp_dir!(), link)

      assert ClaudeSessions.real_path(link) ==
               ClaudeSessions.real_path(System.tmp_dir!())

      if match?({:unix, :darwin}, :os.type()) do
        assert ClaudeSessions.real_path("/tmp") == "/private/tmp"
      end
    end

    test "the task's cwd is resolved through its parent, even with the worktree gone",
         %{tmp_dir: dir} do
      real = Path.join(dir, "real")
      File.mkdir_p!(Path.join(real, "worktrees"))
      link = Path.join(dir, "workdir")
      File.ln_s!(real, link)

      expected = Path.join([ClaudeSessions.real_path(real), "worktrees", "t1"])
      assert ClaudeSessions.task_cwd(link, "t1") == expected

      File.mkdir_p!(Path.join([real, "worktrees", "t1"]))
      assert ClaudeSessions.task_cwd(link, "t1") == expected
    end
  end

  describe "projects_root/1" do
    test "CLAUDE_CONFIG_DIR changes the root" do
      assert ClaudeSessions.projects_root(%{"CLAUDE_CONFIG_DIR" => "/srv/claude"}) ==
               "/srv/claude/projects"
    end

    test "without it, or empty, the root is ~/.claude/projects" do
      home = Path.join(System.user_home!(), ".claude/projects")
      assert ClaudeSessions.projects_root(%{}) == home
      assert ClaudeSessions.projects_root(%{"CLAUDE_CONFIG_DIR" => ""}) == home
    end

    test "a fixed project directory name only counts with CLAUDE_CONFIG_DIR" do
      fixed = %{"CLAUDE_CONFIG_DIR" => "/srv/claude", "CLAUDE_CODE_PROJECT_DIR_NAME" => "shared"}
      assert ClaudeSessions.project_dir_override?(fixed)
      refute ClaudeSessions.project_dir_override?(%{"CLAUDE_CODE_PROJECT_DIR_NAME" => "shared"})
      refute ClaudeSessions.project_dir_override?(%{"CLAUDE_CONFIG_DIR" => "/srv/claude"})

      refute ClaudeSessions.project_dir_override?(%{
               "CLAUDE_CONFIG_DIR" => "/srv/claude",
               "CLAUDE_CODE_PROJECT_DIR_NAME" => "não/vale"
             })
    end
  end

  describe "the marker of a task with a kept session" do
    test "mark/2, marked?/2 and forget/2", %{tmp_dir: workdir} do
      refute ClaudeSessions.marked?(workdir, "t1")

      :ok = ClaudeSessions.mark(workdir, "t1")
      assert ClaudeSessions.marked?(workdir, "t1")
      assert File.regular?(Path.join([workdir, "worktrees", "t1.claude-sessions"]))
      refute ClaudeSessions.marked?(workdir, "t2")

      :ok = ClaudeSessions.forget(workdir, "t1")
      refute ClaudeSessions.marked?(workdir, "t1")
      :ok = ClaudeSessions.forget(workdir, "t1")
    end
  end

  describe "remove/3" do
    setup %{tmp_dir: dir} do
      worktrees = Path.join(dir, "workdir/worktrees")
      File.mkdir_p!(Path.join(worktrees, "t1"))
      cwd = ClaudeSessions.task_cwd(Path.join(dir, "workdir"), "t1")
      root = Path.join(dir, "claude/projects")
      File.mkdir_p!(root)
      %{cwd: cwd, root: root, project: Path.join(root, ClaudeSessions.dir_name(cwd))}
    end

    defp transcript!(path, cwds) do
      File.mkdir_p!(Path.dirname(path))

      lines =
        [~s({"type":"summary","summary":"sem cwd"})] ++
          Enum.map(cwds, &JSON.encode!(%{"type" => "user", "cwd" => &1, "message" => "oi"}))

      File.write!(path, Enum.join(lines, "\n") <> "\n")
    end

    defp file!(path, bytes) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :binary.copy("x", bytes))
    end

    defp size_of(path) do
      case File.lstat!(path) do
        %File.Stat{type: :directory} ->
          path |> File.ls!() |> Enum.map(&size_of(Path.join(path, &1))) |> Enum.sum()

        %File.Stat{size: size} ->
          size
      end
    end

    test "removes only the task's sessions and tells the bytes freed", ctx do
      %{cwd: cwd, root: root, project: project} = ctx

      transcript!(Path.join(project, @session <> ".jsonl"), [cwd, Path.join(cwd, "apps/x")])
      file!(Path.join([project, @session, "tool-results", "b1.txt"]), 3_000)
      file!(Path.join([project, @other_session, "subagents", "agent-1.meta"]), 500)
      file!(Path.join([project, "memory", "MEMORY.md"]), 10)

      others = [
        Path.join(root, ClaudeSessions.dir_name(Path.join(Path.dirname(cwd), "t2"))),
        project <> "-x",
        Path.join(root, "-Users-dev-src-app")
      ]

      for other <- others do
        transcript!(Path.join(other, @session <> ".jsonl"), ["/somewhere/else"])
        file!(Path.join([other, @session, "tool-results", "b1.txt"]), 100)
      end

      expected =
        [
          Path.join(project, @session <> ".jsonl"),
          Path.join(project, @session),
          Path.join(project, @other_session)
        ]
        |> Enum.map(&size_of/1)
        |> Enum.sum()

      assert ClaudeSessions.bytes(root, cwd) == expected
      assert ClaudeSessions.remove(root, cwd, %{}) == {:ok, expected}

      assert File.ls!(project) == ["memory"]
      assert File.read!(Path.join([project, "memory", "MEMORY.md"])) == String.duplicate("x", 10)

      for other <- others do
        assert File.regular?(Path.join(other, @session <> ".jsonl"))
        assert File.regular?(Path.join([other, @session, "tool-results", "b1.txt"]))
      end

      assert ClaudeSessions.bytes(root, cwd) == 0
    end

    test "the project's directory goes when it is left empty", ctx do
      transcript!(Path.join(ctx.project, @session <> ".jsonl"), [ctx.cwd])

      assert {:ok, bytes} = ClaudeSessions.remove(ctx.root, ctx.cwd, %{})
      assert bytes > 0
      refute File.exists?(ctx.project)
      assert File.dir?(ctx.root)
    end

    test "a transcript of another cwd: nothing is removed", ctx do
      transcript!(Path.join(ctx.project, @session <> ".jsonl"), [ctx.cwd])

      transcript!(Path.join(ctx.project, @other_session <> ".jsonl"), [
        ctx.cwd <> "-x",
        ctx.cwd
      ])

      assert ClaudeSessions.remove(ctx.root, ctx.cwd, %{}) == {:error, :cwd_mismatch}
      assert File.regular?(Path.join(ctx.project, @session <> ".jsonl"))
      assert File.regular?(Path.join(ctx.project, @other_session <> ".jsonl"))
    end

    test "a subagent's transcript of another cwd: nothing is removed", ctx do
      transcript!(
        Path.join([ctx.project, @session, "subagents", "agent-a1.jsonl"]),
        ["/Users/dev/src/app"]
      )

      assert ClaudeSessions.remove(ctx.root, ctx.cwd, %{}) == {:error, :cwd_mismatch}
      assert File.dir?(Path.join(ctx.project, @session))
    end

    test "no directory for the cwd", ctx do
      assert ClaudeSessions.remove(ctx.root, ctx.cwd, %{}) == {:error, :not_found}
      assert ClaudeSessions.bytes(ctx.root, ctx.cwd) == 0
    end

    test "only session subdirectories (a run without a kept session) go too", ctx do
      file!(Path.join([ctx.project, @session, "tool-results", "b1.txt"]), 1_000)

      assert {:ok, bytes} = ClaudeSessions.remove(ctx.root, ctx.cwd, %{})
      assert bytes >= 1_000
      refute File.exists?(ctx.project)
    end

    test "entries that are not sessions stay", ctx do
      transcript!(Path.join(ctx.project, @session <> ".jsonl"), [ctx.cwd])
      file!(Path.join(ctx.project, "notas.txt"), 5)
      file!(Path.join(ctx.project, "not-a-uuid.jsonl"), 5)
      File.ln_s!(Path.join(ctx.root, ".."), Path.join(ctx.project, @other_session))

      assert {:ok, _bytes} = ClaudeSessions.remove(ctx.root, ctx.cwd, %{})

      assert Enum.sort(File.ls!(ctx.project)) ==
               Enum.sort(["notas.txt", "not-a-uuid.jsonl", @other_session])

      assert File.dir?(Path.join(ctx.root, ".."))
    end

    test "with a fixed project directory name, the directory is shared: nothing goes", ctx do
      transcript!(Path.join(ctx.project, @session <> ".jsonl"), [ctx.cwd])
      env = %{"CLAUDE_CONFIG_DIR" => "/srv/claude", "CLAUDE_CODE_PROJECT_DIR_NAME" => "shared"}

      assert ClaudeSessions.remove(ctx.root, ctx.cwd, env) == {:error, :shared_project_dir}
      assert File.regular?(Path.join(ctx.project, @session <> ".jsonl"))
    end
  end
end
