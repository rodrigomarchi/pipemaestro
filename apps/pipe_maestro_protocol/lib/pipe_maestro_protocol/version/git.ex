defmodule PipeMaestroProtocol.Version.Git do
  @moduledoc """
  Reads the version scheme (`PipeMaestroProtocol.Version`) from the git
  repository a directory is in: the version of a build of it, the runner's
  version and the next release to cut.

  The control plane's version (`current/1`) follows `HEAD`. The runner's
  (`runner/1`) follows the last commit that changed a path that goes into the
  runner's binary (`runner_paths/0`), so a commit elsewhere keeps it.

  `CP_VERSION` and `RUNNER_VERSION`, when set, are each one's version as it is
  (a build without `.git`, such as the Docker image, or one that pins its
  version). Without git or outside a repository, a build is `dev+unknown`.
  """

  alias PipeMaestroProtocol.Version

  @release_tags "runner-*"

  @runner_paths [
    "apps/pipe_maestro_runner",
    "apps/pipe_maestro_protocol",
    "config",
    "mix.exs",
    "mix.lock",
    ".tool-versions",
    "docker/runner-binary",
    "scripts/build_runner_binaries.sh"
  ]

  @doc "The version of a build of the repository `dir` is in."
  @spec current(Path.t()) :: String.t()
  def current(dir) do
    case System.get_env("CP_VERSION") do
      version when is_binary(version) and version != "" -> version
      _unset -> from_git(dir)
    end
  end

  @doc """
  The runner's version for the repository `dir` is in: the scheme applied to
  the last commit that changed one of `runner_paths/0`.
  """
  @spec runner(Path.t()) :: String.t()
  def runner(dir) do
    case System.get_env("RUNNER_VERSION") do
      version when is_binary(version) and version != "" -> version
      _unset -> runner_from_git(dir)
    end
  end

  @doc """
  The paths, relative to the repository's root, whose changes go into the
  runner's binary: its app, the apps it depends on and the build's inputs.
  """
  @spec runner_paths() :: [String.t()]
  def runner_paths, do: @runner_paths

  @doc "The release to cut on `date`, after the repository's release tags."
  @spec next(Path.t(), Date.t()) :: String.t()
  def next(dir, %Date{} = date) do
    tags = git(dir, ["tag", "--list", @release_tags]) || ""
    Version.next(lines(tags), date)
  end

  @doc "This machine's local date, the one a release is named after."
  @spec local_today() :: Date.t()
  def local_today do
    {{year, month, day}, _time} = :calendar.local_time()
    Date.new!(year, month, day)
  end

  defp from_git(dir) do
    case git(dir, ["rev-parse", "--short", "HEAD"]) do
      nil ->
        "dev+unknown"

      sha ->
        head = git(dir, ["tag", "--points-at", "HEAD", "--list", @release_tags]) || ""
        reachable = git(dir, ["tag", "--merged", "HEAD", "--list", @release_tags]) || ""
        Version.describe(lines(head), lines(reachable), String.trim(sha))
    end
  end

  defp runner_from_git(dir) do
    with root when is_binary(root) <- git(dir, ["rev-parse", "--show-toplevel"]),
         root = String.trim(root),
         log when is_binary(log) <-
           git(root, ["log", "-1", "--format=%h", "--" | @runner_paths]),
         sha when sha != "" <- String.trim(log) do
      at = git(root, ["tag", "--points-at", sha, "--list", @release_tags]) || ""
      reachable = git(root, ["tag", "--merged", sha, "--list", @release_tags]) || ""
      Version.describe(lines(at), lines(reachable), sha)
    else
      _no_repository_or_commit -> "dev+unknown"
    end
  end

  defp git(dir, args) do
    with git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <- System.cmd(git, ["-C", dir | args], stderr_to_stdout: true) do
      output
    else
      _no_git_or_repository -> nil
    end
  end

  defp lines(output), do: String.split(output, "\n", trim: true)
end
