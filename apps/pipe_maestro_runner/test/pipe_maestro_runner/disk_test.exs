defmodule PipeMaestroRunner.DiskTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.{ClaudeSessions, Disk}

  @moduletag :tmp_dir

  test "counts the worktrees and the space they take", %{tmp_dir: workdir} do
    assert %{"count" => 0, "bytes" => 0} = Disk.usage(workdir)

    for task <- ~w(t1 t2) do
      File.mkdir_p!(Path.join([workdir, "worktrees", task]))
      File.write!(Path.join([workdir, "worktrees", task, "big"]), :binary.copy("x", 100_000))
    end

    usage = Disk.usage(workdir)
    assert usage["count"] == 2
    assert usage["bytes"] >= 200_000
    assert is_integer(usage["free_bytes"]) and usage["free_bytes"] > 0
  end

  test "the space counts the CLI's sessions of each worktree, and drops when they go",
       %{tmp_dir: dir} do
    workdir = Path.join(dir, "workdir")
    root = Path.join(dir, "claude/projects")
    File.mkdir_p!(Path.join([workdir, "worktrees", "t1"]))
    File.mkdir_p!(root)

    without = Disk.usage(workdir, root)["bytes"]

    cwd = ClaudeSessions.task_cwd(workdir, "t1")
    project = Path.join(root, ClaudeSessions.dir_name(cwd))
    File.mkdir_p!(project)

    File.write!(
      Path.join(project, "2f517ed4-46fa-4ab0-a237-840babadcd65.jsonl"),
      JSON.encode!(%{"cwd" => cwd, "pad" => :binary.copy("x", 200_000)}) <> "\n"
    )

    # Another cwd's sessions are not the runner's.
    other = Path.join(root, "-Users-dev-src-app")
    File.mkdir_p!(other)

    File.write!(
      Path.join(other, "607a4c45-7c11-44c7-a5d7-ef9ecefd17a3.jsonl"),
      :binary.copy("x", 500_000)
    )

    with_sessions = Disk.usage(workdir, root)
    assert with_sessions["count"] == 1
    assert with_sessions["bytes"] >= without + 200_000
    assert with_sessions["bytes"] < without + 500_000

    {:ok, freed} = ClaudeSessions.remove(root, cwd, %{})
    assert Disk.usage(workdir, root)["bytes"] <= with_sessions["bytes"] - freed
  end
end
