defmodule ClaudeControlPlaneRunner.SetupTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneRunner.Setup

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "app")
    worktree = Path.join(dir, "worktree")
    File.mkdir_p!(Path.join([source, "deps", "jason"]))
    File.write!(Path.join([source, "deps", "jason", "mix.exs"]), "jason")
    File.mkdir_p!(Path.join([source, "_build", "dev"]))
    File.mkdir_p!(Path.join([source, "vendor", "bundle"]))
    File.mkdir_p!(Path.join(source, "lib"))
    File.mkdir_p!(Path.join(worktree, "lib"))
    %{source: source, worktree: worktree}
  end

  test "detect finds the usual dependency and build directories", %{source: source} do
    assert Setup.detect(source) == ["deps", "_build", "vendor/bundle"]
  end

  test "copies what is missing in the worktree and keeps what is there", %{
    source: source,
    worktree: worktree
  } do
    report = Setup.run(source, worktree, %{"copy" => ["deps", "lib", "nao-existe"]})

    assert report["copied"] == ["deps"]
    assert File.read!(Path.join([worktree, "deps", "jason", "mix.exs"])) == "jason"
    assert report["command"] == nil
    assert is_integer(report["duration_ms"])

    # The copy is independent of the source.
    File.write!(Path.join([worktree, "deps", "jason", "mix.exs"]), "mudou")
    assert File.read!(Path.join([source, "deps", "jason", "mix.exs"])) == "jason"
  end

  test "without a list, copies what it detects", %{source: source, worktree: worktree} do
    assert Setup.run(source, worktree, nil)["copied"] == ["deps", "_build", "vendor/bundle"]
    assert File.dir?(Path.join([worktree, "vendor", "bundle"]))
  end

  test "runs the command in the worktree and reports its exit and output", %{
    source: source,
    worktree: worktree
  } do
    report = Setup.run(source, worktree, %{"copy" => [], "command" => "pwd; echo pronto"})
    assert report["exit_code"] == 0
    assert report["output"] =~ "pronto"
    assert report["output"] =~ Path.basename(worktree)

    report = Setup.run(source, worktree, %{"copy" => [], "command" => "echo ruim >&2; exit 3"})
    assert report["exit_code"] == 3
    assert report["output"] =~ "ruim"
  end

  test "keeps the end of a long output, cut at a character boundary", %{
    source: source,
    worktree: worktree
  } do
    command = "i=0; while [ $i -lt 3000 ]; do printf 'ação'; i=$((i+1)); done; echo fim"
    report = Setup.run(source, worktree, %{"copy" => [], "command" => command})

    assert String.valid?(report["output"])
    assert byte_size(report["output"]) in 8_000..8_192
    assert report["output"] =~ ~r/açãofim\n$/
  end

  test "reports the command's process so it can be stopped", %{
    source: source,
    worktree: worktree
  } do
    test_pid = self()

    task =
      Task.async(fn ->
        Setup.run(source, worktree, %{"command" => "sleep 30"},
          on_os_pid: &send(test_pid, {:os_pid, &1})
        )
      end)

    assert_receive {:os_pid, os_pid}
    System.cmd("kill", ["-s", "TERM", "--", "-#{os_pid}"])
    assert %{"exit_code" => code} = Task.await(task)
    assert code != 0
  end
end
