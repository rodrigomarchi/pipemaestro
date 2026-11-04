defmodule ClaudeControlPlaneProtocol.Version.Git do
  @moduledoc """
  Reads the version scheme (`ClaudeControlPlaneProtocol.Version`) from the git
  repository a directory is in: the version of a build of it and the next
  release to cut.

  `CP_VERSION`, when set, is the version as it is (a build without `.git`, such
  as the Docker image, or one that pins its version). Without git or outside a
  repository, a build is `dev+unknown`.
  """

  alias ClaudeControlPlaneProtocol.Version

  @release_tags "runner-*"

  @doc "The version of a build of the repository `dir` is in."
  @spec current(Path.t()) :: String.t()
  def current(dir) do
    case System.get_env("CP_VERSION") do
      version when is_binary(version) and version != "" -> version
      _unset -> from_git(dir)
    end
  end

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
