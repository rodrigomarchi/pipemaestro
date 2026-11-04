defmodule PipeMaestroRunner.DiskTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Disk

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
end
