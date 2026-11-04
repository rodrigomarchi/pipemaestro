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
end
