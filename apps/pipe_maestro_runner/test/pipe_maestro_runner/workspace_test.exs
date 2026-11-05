defmodule PipeMaestroRunner.WorkspaceTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.Job
  alias PipeMaestroRunner.{Directories, Workspace}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "src")
    File.mkdir_p!(Path.join([root, "app", ".git"]))
    File.mkdir_p!(Path.join(root, "notas"))
    File.mkdir_p!(Path.join(root, ".escondido"))
    File.write!(Path.join(root, "arquivo.txt"), "não é diretório")
    %{root: root, workdir: Path.join(dir, "workdir")}
  end

  test "Directories lists the first level, marking git repositories", %{root: root} do
    assert Directories.scan(root) == [
             %{"name" => "app", "git" => true},
             %{"name" => "notas", "git" => false}
           ]

    assert Directories.scan(nil) == []
    assert Directories.scan(Path.join(root, "nao-existe")) == []
  end

  test "a job on its own runs in the workdir", %{root: root, workdir: workdir} do
    assert Workspace.prepare(%Job{id: "j", prompt: "p"}, root, workdir) == {:ok, workdir, nil}
  end

  test "a directory without a worktree runs in place", %{root: root, workdir: workdir} do
    job = %Job{id: "j", prompt: "p", directory: "notas"}
    assert Workspace.prepare(job, root, workdir) == {:ok, Path.join(root, "notas"), nil}
  end

  test "refuses without a root, or a directory that is not there", %{root: root, workdir: workdir} do
    job = %Job{id: "j", prompt: "p", directory: "notas"}

    assert {:error, "Este runner não tem diretório raiz" <> _} =
             Workspace.prepare(job, nil, workdir)

    assert {:error, "O diretório nao-existe não existe" <> _} =
             Workspace.prepare(%{job | directory: "nao-existe"}, root, workdir)
  end

  test "a directory that is not itself a repository root gets no worktree", %{
    root: root,
    workdir: workdir
  } do
    job = %Job{
      id: "j",
      prompt: "p",
      directory: "app",
      worktree: %{"task_id" => "t1", "branch" => "cp/t1"}
    }

    # app/.git is not a real repository: git would find the enclosing one.
    assert {:error, "O diretório app não é a raiz de um repositório git."} =
             Workspace.prepare(job, root, workdir)

    refute File.exists?(Path.join(workdir, "worktrees"))
  end

  test "removing a worktree that cannot be deleted reports why", %{root: root, workdir: workdir} do
    path = Path.join([workdir, "worktrees", "t1"])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "preso"), "x")
    File.chmod!(path, 0o555)

    try do
      assert {:error, "Não foi possível apagar " <> _} =
               Workspace.remove_task_worktree(root, workdir, "t1", "notas")
    after
      File.chmod!(path, 0o755)
    end

    assert Workspace.remove_task_worktree(root, workdir, "t1", "notas") == :ok
    refute File.exists?(path)
  end

  describe "a task's worktree" do
    defp git!(dir, args) do
      {out, 0} =
        System.cmd("git", ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" | args],
          stderr_to_stdout: true
        )

      String.trim(out)
    end

    # `src/repo`, a clone of a bare `origin.git` with one commit on main.
    setup %{tmp_dir: dir, root: root} do
      origin = Path.join(dir, "origin.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", origin])
      repo = Path.join(root, "repo")
      {_, 0} = System.cmd("git", ["clone", "-q", origin, repo], stderr_to_stdout: true)
      File.write!(Path.join(repo, "README.md"), "app")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-q", "-m", "init"])
      git!(repo, ["push", "-q", "origin", "HEAD:main"])
      %{repo: repo, origin: origin}
    end

    defp job(task_id, branch),
      do: %Job{
        id: "j-#{task_id}",
        prompt: "x",
        directory: "repo",
        worktree: %{"task_id" => task_id, "branch" => branch}
      }

    test "a new task's branch starts from HEAD", %{root: root, workdir: workdir, repo: repo} do
      assert {:ok, path, ^repo} = Workspace.prepare(job("t1", "cp/nova"), root, workdir)
      assert git!(path, ["rev-parse", "HEAD"]) == git!(repo, ["rev-parse", "HEAD"])
      assert git!(path, ["branch", "--show-current"]) == "cp/nova"
    end

    test "a branch that is only on origin is checked out from there", ctx do
      %{root: root, workdir: workdir, repo: repo} = ctx
      git!(repo, ["checkout", "-q", "-b", "cp/feita"])
      File.write!(Path.join(repo, "lib.ex"), "trabalho")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-q", "-m", "trabalho"])
      git!(repo, ["push", "-q", "origin", "cp/feita"])
      pushed = git!(repo, ["rev-parse", "HEAD"])
      git!(repo, ["checkout", "-q", "main"])
      git!(repo, ["branch", "-q", "-D", "cp/feita"])
      git!(repo, ["update-ref", "-d", "refs/remotes/origin/cp/feita"])

      assert {:ok, path, ^repo} = Workspace.prepare(job("t2", "cp/feita"), root, workdir)
      assert git!(path, ["rev-parse", "HEAD"]) == pushed
      assert File.read!(Path.join(path, "lib.ex")) == "trabalho"
    end

    test "a worktree removed is made again on its branch", ctx do
      %{root: root, workdir: workdir, repo: repo} = ctx
      {:ok, path, _} = Workspace.prepare(job("t3", "cp/de-volta"), root, workdir)
      File.write!(Path.join(path, "a.ex"), "a")
      git!(path, ["add", "."])
      git!(path, ["commit", "-q", "-m", "a"])
      commit = git!(path, ["rev-parse", "HEAD"])
      assert Workspace.remove_task_worktree(root, workdir, "t3", "repo") == :ok

      assert {:ok, ^path, ^repo} = Workspace.prepare(job("t3", "cp/de-volta"), root, workdir)
      assert git!(path, ["rev-parse", "HEAD"]) == commit
    end
  end
end
