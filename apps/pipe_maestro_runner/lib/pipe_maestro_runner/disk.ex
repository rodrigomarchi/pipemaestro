defmodule PipeMaestroRunner.Disk do
  @moduledoc """
  The space the runner's task worktrees take, in the wire form of
  `PipeMaestroProtocol.Worktree`'s `worktree:usage`. Measured with `du`
  and `df`, so it may take a moment on large worktrees: call it off any
  process that must stay responsive.
  """

  @doc "How many worktrees `workdir` keeps, their size and the free space."
  @spec usage(Path.t()) :: %{String.t() => non_neg_integer() | nil}
  def usage(workdir) do
    dir = Path.join(workdir, "worktrees")

    count =
      case File.ls(dir) do
        {:ok, names} -> Enum.count(names, &File.dir?(Path.join(dir, &1)))
        {:error, _reason} -> 0
      end

    %{
      "count" => count,
      "bytes" => if(count > 0, do: kilobytes(System.cmd("du", ["-sk", dir])), else: 0),
      "free_bytes" => free_bytes(workdir)
    }
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
