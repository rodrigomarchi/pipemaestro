defmodule PipeMaestroProtocol.Version.GitTest do
  # Reads and changes CP_VERSION and RUNNER_VERSION, which are global to the VM.
  use ExUnit.Case, async: false

  alias PipeMaestroProtocol.Version.Git

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    for name <- ["CP_VERSION", "RUNNER_VERSION"] do
      previous = System.get_env(name)
      System.delete_env(name)

      on_exit(fn ->
        if previous,
          do: System.put_env(name, previous),
          else: System.delete_env(name)
      end)
    end

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

  # Commits a change to `path`, relative to the repository's root.
  defp change!(repo, path, message \\ nil) do
    file = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "#{System.unique_integer([:positive])}\n", [:append])
    git!(repo, ["add", "--", path])
    git!(repo, ["commit", "-q", "-m", message || "change #{path}"])
    sha(repo)
  end

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

  describe "the runner's version" do
    test "comes from the paths that go into the runner's binary" do
      paths = Git.runner_paths()

      for path <-
            ~w(apps/pipe_maestro_runner apps/pipe_maestro_protocol config mix.exs mix.lock .tool-versions docker/runner-binary scripts/build_runner_binaries.sh) do
        assert Enum.any?(paths, &(String.trim_trailing(&1, "/") == path)),
               "#{path} is not among the runner's paths: #{inspect(paths)}"
      end

      for path <- ~w(apps/pipe_maestro apps/pipe_maestro_web docs e2e) do
        refute Enum.any?(paths, &(String.trim_trailing(&1, "/") == path)),
               "#{path} does not go into the runner's binary"
      end
    end

    test "is the last commit that changed the runner, not HEAD", %{repo: repo} do
      runner_commit = change!(repo, "apps/pipe_maestro_runner/lib/runner.ex")
      assert Git.runner(repo) == "dev+#{runner_commit}"

      for path <- [
            "apps/pipe_maestro_web/lib/page.ex",
            "apps/pipe_maestro/lib/domain.ex",
            "docs/guide.md",
            "e2e/tests/flow.spec.ts"
          ] do
        head = change!(repo, path)

        assert Git.runner(repo) == "dev+#{runner_commit}",
               "a change to #{path} changed the runner's version"

        assert Git.current(repo) == "dev+#{head}"
      end
    end

    test "changes with any path that goes into the runner's binary", %{repo: repo} do
      change!(repo, "apps/pipe_maestro_web/lib/page.ex")

      for path <- [
            "apps/pipe_maestro_runner/lib/runner.ex",
            "apps/pipe_maestro_protocol/lib/hello.ex",
            "config/config.exs",
            "mix.exs",
            "mix.lock",
            ".tool-versions",
            "docker/runner-binary/Dockerfile",
            "scripts/build_runner_binaries.sh"
          ] do
        before = Git.runner(repo)
        commit = change!(repo, path)

        assert Git.runner(repo) == "dev+#{commit}", "a change to #{path} kept #{before}"
      end
    end

    test "is computed from the repository's root, from any directory in it", %{repo: repo} do
      runner_commit = change!(repo, "apps/pipe_maestro_runner/lib/runner.ex")
      change!(repo, "apps/pipe_maestro_web/lib/page.ex")

      assert Git.runner(Path.join(repo, "apps/pipe_maestro_web/lib")) == "dev+#{runner_commit}"
    end

    test "at a release tag on the runner's commit, that release", %{repo: repo} do
      change!(repo, "apps/pipe_maestro_runner/lib/runner.ex")
      tag!(repo, "runner-2026-11-04.01")
      head = change!(repo, "apps/pipe_maestro_web/lib/page.ex")

      assert Git.runner(repo) == "2026-11-04.01"
      assert Git.current(repo) == "2026-11-04.01+dev.#{head}"
    end

    test "after a release, a development build of the runner's commit on top of it", %{
      repo: repo
    } do
      change!(repo, "apps/pipe_maestro_runner/lib/runner.ex")
      tag!(repo, "runner-2026-11-04.01")
      runner_commit = change!(repo, "apps/pipe_maestro_protocol/lib/hello.ex")
      change!(repo, "apps/pipe_maestro_web/lib/page.ex")
      # A tag on a later commit than the runner's does not name the runner.
      tag!(repo, "runner-2026-11-04.02")

      assert Git.runner(repo) == "2026-11-04.01+dev.#{runner_commit}"
    end

    test "RUNNER_VERSION, when set, is the version as it is", %{repo: repo} do
      change!(repo, "apps/pipe_maestro_runner/lib/runner.ex")
      System.put_env("RUNNER_VERSION", "2026-11-03.01")

      assert Git.runner(repo) == "2026-11-03.01"
    end

    test "an empty RUNNER_VERSION does not count", %{repo: repo} do
      runner_commit = change!(repo, "apps/pipe_maestro_runner/lib/runner.ex")
      System.put_env("RUNNER_VERSION", "")

      assert Git.runner(repo) == "dev+#{runner_commit}"
    end

    test "CP_VERSION is the control plane's only", %{repo: repo} do
      runner_commit = change!(repo, "apps/pipe_maestro_runner/lib/runner.ex")
      System.put_env("CP_VERSION", "2026-11-04.09")

      assert Git.current(repo) == "2026-11-04.09"
      assert Git.runner(repo) == "dev+#{runner_commit}"
    end

    test "a directory outside any repository is dev+unknown" do
      outside =
        Path.join(System.tmp_dir!(), "runner-version-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      assert Git.runner(outside) == "dev+unknown"
    end
  end

  test "the local date is a date" do
    assert %Date{} = Git.local_today()
  end
end
