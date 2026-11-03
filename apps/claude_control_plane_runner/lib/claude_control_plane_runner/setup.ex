defmodule ClaudeControlPlaneRunner.Setup do
  @moduledoc """
  Prepares a task's worktree once, right after it is created, so the first
  stage does not pay for installing and building:

    1. clones paths of the source directory that git does not carry
       (dependencies, build output) into the worktree, copy-on-write where the
       file system allows (`cp -c` on APFS, `--reflink` on Linux), so the
       clone is quick and takes no extra space until it diverges;
    2. runs the setup command, if there is one, in the worktree.

  The paths come from the job's `setup` (`ClaudeControlPlaneProtocol.Job`) or,
  without a list, from `detect/1`. A path the worktree already has (tracked by
  git) is left alone.
  """

  alias ClaudeControlPlaneRunner.Shell

  @candidates ~w(deps _build node_modules .venv venv vendor/bundle target)

  @typedoc "What a setup did, in the wire form of `job:finished`'s `setup`."
  @type report :: %{String.t() => term()}

  @doc "The usual dependency and build directories `source` has."
  @spec detect(Path.t()) :: [String.t()]
  def detect(source), do: Enum.filter(@candidates, &File.dir?(Path.join(source, &1)))

  @doc """
  Prepares `worktree` from `source` as `setup` says (`nil`: detect the paths,
  no command). Option `:on_os_pid` is called with the OS pid of the setup
  command, which leads its own process group, so the caller can stop it.
  """
  @spec run(Path.t(), Path.t(), map() | nil, keyword()) :: report()
  def run(source, worktree, setup, opts \\ []) do
    setup = setup || %{}
    started = System.monotonic_time(:millisecond)
    copied = setup |> Map.get_lazy("copy", fn -> detect(source) end) |> copy(source, worktree)

    report = %{"copied" => copied, "command" => setup["command"]}

    report =
      case setup["command"] do
        nil ->
          report

        command ->
          {exit_code, output} = Shell.run(worktree, command, opts[:on_os_pid])
          Map.merge(report, %{"exit_code" => exit_code, "output" => output})
      end

    Map.put(report, "duration_ms", System.monotonic_time(:millisecond) - started)
  end

  defp copy(paths, source, worktree) do
    Enum.filter(paths, fn path ->
      from = Path.join(source, path)
      to = Path.join(worktree, path)

      File.dir?(from) and not File.exists?(to) and clone(from, to)
    end)
  end

  defp clone(from, to) do
    File.mkdir_p!(Path.dirname(to))

    Enum.any?(clone_commands(from, to), fn args ->
      match?({_output, 0}, System.cmd("cp", args, stderr_to_stdout: true))
    end)
  end

  # Copy-on-write first; a plain copy when the file system cannot clone.
  defp clone_commands(from, to) do
    case :os.type() do
      {:unix, :darwin} -> [["-c", "-pR", from, to], ["-pR", from, to]]
      _other -> [["-a", "--reflink=auto", from, to], ["-pR", from, to]]
    end
  end
end
