defmodule PipeMaestroRunner.GatesTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.{GateCache, Gates}

  @moduletag :tmp_dir

  @isolated [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" | args],
        stderr_to_stdout: true,
        env: @isolated
      )

    String.trim(out)
  end

  # A repository whose gate counts its runs in a file git ignores.
  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, ".gitignore"), "runs\n")
    File.write!(Path.join(repo, "lib.ex"), "v1")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "inicio"])
    %{repo: repo}
  end

  defp gate(command, expect \\ "pass"), do: %{"command" => command, "expect" => expect}

  defp counting(exit_code \\ 0), do: gate("echo x >> runs; exit #{exit_code}")

  defp runs(repo) do
    case File.read(Path.join(repo, "runs")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> length()
      {:error, _} -> 0
    end
  end

  test "a gate that passed is not run again on the same tree", %{repo: repo} do
    assert [%{"passed" => true, "exit_code" => 0} = first] = Gates.run(repo, [counting()])
    refute first["cached"]

    assert [%{"passed" => true, "cached" => true, "duration_ms" => 0, "exit_code" => 0} = again] =
             Gates.run(repo, [counting()])

    assert again["output"] =~ "já passou nesta mesma árvore"
    assert runs(repo) == 1
  end

  test "a change to the tree runs it again, committed or not", %{repo: repo} do
    Gates.run(repo, [counting()])

    File.write!(Path.join(repo, "lib.ex"), "v2")
    assert [%{"passed" => true} = changed] = Gates.run(repo, [counting()])
    refute changed["cached"]

    File.write!(Path.join(repo, "novo.ex"), "novo")
    Gates.run(repo, [counting()])

    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "mudanca"])
    assert [%{"cached" => true}] = Gates.run(repo, [counting()])
    assert runs(repo) == 3
  end

  test "the excluded paths do not change the tree", %{repo: repo} do
    artifacts = ".control-plane/t"
    Gates.run(repo, [counting()], exclude: [artifacts])

    File.mkdir_p!(Path.join(repo, artifacts))
    File.write!(Path.join([repo, artifacts, "01-plano.md"]), "# Plano")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "artefato"])

    assert [%{"cached" => true}] = Gates.run(repo, [counting()], exclude: [artifacts])
    assert [changed] = Gates.run(repo, [counting()])
    refute changed["cached"]
  end

  test "a gate that failed is never kept", %{repo: repo} do
    assert [%{"passed" => false}] = Gates.run(repo, [counting(1)])
    assert [%{"passed" => false} = again] = Gates.run(repo, [counting(1)])
    refute again["cached"]
    assert runs(repo) == 2
  end

  test "a gate expected to fail is kept once it failed", %{repo: repo} do
    failing = gate("echo x >> runs; exit 2", "fail")
    assert [%{"passed" => true, "exit_code" => 2}] = Gates.run(repo, [failing])
    assert [%{"passed" => true, "cached" => true, "exit_code" => 2}] = Gates.run(repo, [failing])
    assert runs(repo) == 1
  end

  test "a gate that reads the remote always runs", %{repo: repo} do
    remote = gate("echo x >> runs; git rev-parse HEAD >/dev/null # origin/main")
    refute GateCache.cacheable?("git fetch --quiet origin && true")
    Gates.run(repo, [remote])
    assert [again] = Gates.run(repo, [remote])
    refute again["cached"]
    assert runs(repo) == 2
  end

  test "the command and the expectation are part of the key", %{repo: repo} do
    Gates.run(repo, [counting()])
    assert [other] = Gates.run(repo, [gate("echo y >> runs")])
    refute other["cached"]
  end

  test "outside git every gate runs", _ctx do
    plain =
      Path.join(System.tmp_dir!(), "pipemaestro-gates-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(plain) end)
    File.mkdir_p!(plain)
    assert GateCache.open(plain) == nil
    Gates.run(plain, [counting()])
    assert [again] = Gates.run(plain, [counting()])
    refute again["cached"]
  end

  test "in a directory its repository ignores every gate runs", %{tmp_dir: dir} do
    # The test's tmp_dir sits under this repository's ignored tmp/.
    plain = Path.join(dir, "plain")
    File.mkdir_p!(plain)
    assert GateCache.open(plain) == nil
    Gates.run(plain, [counting()])
    assert [again] = Gates.run(plain, [counting()])
    refute again["cached"]
    assert runs(plain) == 2
  end

  test "the cache lives in the git dir and survives a broken file", %{repo: repo} do
    Gates.run(repo, [counting()])
    file = Path.join([repo, ".git", "pipemaestro-gates.json"])
    assert File.exists?(file)

    File.write!(file, "não é json")
    assert [again] = Gates.run(repo, [counting()])
    refute again["cached"]
    assert [%{"cached" => true}] = Gates.run(repo, [counting()])
  end

  test "it hands each command's OS pid to whoever may stop it", %{repo: repo} do
    me = self()
    Gates.run(repo, [counting()], on_os_pid: &send(me, {:pid, &1}))
    assert_received {:pid, pid} when is_integer(pid)
  end
end
