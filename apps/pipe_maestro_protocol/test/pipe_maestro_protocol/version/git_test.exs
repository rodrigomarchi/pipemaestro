defmodule PipeMaestroProtocol.Version.GitTest do
  # Reads and changes CP_VERSION, which is global to the VM.
  use ExUnit.Case, async: false

  alias PipeMaestroProtocol.Version.Git

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = System.get_env("CP_VERSION")
    System.delete_env("CP_VERSION")

    on_exit(fn ->
      if previous,
        do: System.put_env("CP_VERSION", previous),
        else: System.delete_env("CP_VERSION")
    end)

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    commit!(repo, "first")

    %{repo: repo}
  end

  defp git!(repo, args) do
    config = [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "tag.gpgsign=false"
    ]

    {out, 0} = System.cmd("git", config ++ ["-C", repo | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit!(repo, message), do: git!(repo, ["commit", "-q", "--allow-empty", "-m", message])

  defp tag!(repo, name), do: git!(repo, ["tag", "-a", name, "-m", name])

  defp sha(repo), do: git!(repo, ["rev-parse", "--short", "HEAD"])

  test "without any release tag, dev and the commit", %{repo: repo} do
    tag!(repo, "v1.2.3")
    assert Git.current(repo) == "dev+#{sha(repo)}"
  end

  test "at a release tag, that release", %{repo: repo} do
    tag!(repo, "runner-2026-11-04.01")
    assert Git.current(repo) == "2026-11-04.01"
  end

  test "a commit after the tag is a development build on top of it", %{repo: repo} do
    tag!(repo, "runner-2026-11-04.01")
    commit!(repo, "second")

    assert Git.current(repo) == "2026-11-04.01+dev.#{sha(repo)}"
  end

  test "a tag that HEAD cannot reach does not count", %{repo: repo} do
    tag!(repo, "runner-2026-11-03.01")
    git!(repo, ["switch", "-q", "-c", "other"])
    commit!(repo, "elsewhere")
    tag!(repo, "runner-2026-11-04.01")
    git!(repo, ["switch", "-q", "main"])
    commit!(repo, "second")

    assert Git.current(repo) == "2026-11-03.01+dev.#{sha(repo)}"
  end

  test "the next release follows the day's tags", %{repo: repo} do
    assert Git.next(repo, ~D[2026-11-04]) == "2026-11-04.01"

    tag!(repo, "runner-2026-11-04.01")
    commit!(repo, "second")
    tag!(repo, "runner-2026-11-04.02")

    assert Git.next(repo, ~D[2026-11-04]) == "2026-11-04.03"
    assert Git.next(repo, ~D[2026-11-05]) == "2026-11-05.01"
  end

  test "CP_VERSION, when set, is the version as it is", %{repo: repo} do
    tag!(repo, "runner-2026-11-04.01")
    System.put_env("CP_VERSION", "2026-11-04.09")

    assert Git.current(repo) == "2026-11-04.09"
  end

  test "a directory outside any repository is dev+unknown" do
    # ExUnit's tmp_dir lives inside this checkout, which is itself a repository.
    outside = Path.join(System.tmp_dir!(), "cp-version-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert Git.current(outside) == "dev+unknown"
  end

  test "the local date is a date" do
    assert %Date{} = Git.local_today()
  end
end
