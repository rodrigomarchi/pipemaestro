defmodule PipeMaestroRunner.Disk do
  @moduledoc """
  The space the runner's task worktrees take, in the wire form of
  `PipeMaestroProtocol.Worktree`'s `worktree:usage`: the worktrees and the
  agent CLI's sessions of each (`PipeMaestroRunner.ClaudeSessions`), which go
  with it. Measured with `du` and `df`, so it may take a moment on large
  worktrees: call it off any process that must stay responsive.
  """

  alias PipeMaestroRunner.ClaudeSessions

  @doc """
  How many worktrees `workdir` keeps, their size (with the CLI's sessions of
  each, under `claude_projects`) and the free space.
  """
  @spec usage(Path.t(), Path.t()) :: %{String.t() => non_neg_integer() | nil}
  def usage(workdir, claude_projects \\ ClaudeSessions.projects_root()) do
    dir = Path.join(workdir, "worktrees")

    tasks =
      case File.ls(dir) do
        {:ok, names} -> Enum.filter(names, &File.dir?(Path.join(dir, &1)))
        {:error, _reason} -> []
      end

    %{
      "count" => length(tasks),
      "bytes" => worktree_bytes(dir, tasks) + session_bytes(workdir, tasks, claude_projects),
      "free_bytes" => free_bytes(workdir)
    }
  end

  defp worktree_bytes(_dir, []), do: 0
  defp worktree_bytes(dir, _tasks), do: kilobytes(System.cmd("du", ["-sk", dir])) || 0

  defp session_bytes(workdir, tasks, claude_projects) do
    tasks
    |> Enum.map(&ClaudeSessions.bytes(claude_projects, ClaudeSessions.task_cwd(workdir, &1)))
    |> Enum.sum()
  end

  defp free_bytes(path) do
    case System.cmd("df", ["-k", path], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last()
        |> String.split()
        |> Enum.at(3)
        |> parse_kilobytes()

      _failed ->
        nil
    end
  end

  defp kilobytes({output, 0}), do: output |> String.split() |> List.first() |> parse_kilobytes()
  defp kilobytes(_failed), do: 0

  defp parse_kilobytes(text) do
    case Integer.parse(text || "") do
      {kb, _rest} -> kb * 1024
      :error -> nil
    end
  end
end
