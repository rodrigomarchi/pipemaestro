defmodule ClaudeControlPlaneRunner.Changes do
  @moduledoc """
  What a stage changed in a task's worktree, measured with git alone.

  A snapshot is the git tree of the worktree's files as they are (tracked or
  not, ignored files left out), written through a temporary index so neither
  the worktree's index nor its commits are touched: what the agent stages or
  commits does not change what the snapshot sees. Two snapshots give the
  files changed between them, with lines added and removed, and the patch.

  Paths cloned into the worktree by the setup (`ClaudeControlPlaneRunner.Setup`)
  are left out of snapshots: they are dependencies, not the task's work.
  """

  @patch_bytes 200_000

  @typedoc "Where a stage started from: the task's first snapshot and this stage's."
  @type tracking :: %{base: String.t(), start: String.t(), exclude: [String.t()]}

  @doc """
  Takes the snapshot a stage starts from, in the worktree `dir` of task
  `task_id`. A new worktree (`new?`) also records it as the task's base, with
  the paths to leave out, in `<workdir>/worktrees/<task_id>.json`; later stages
  read them from there. `nil` when there is nothing to compare with.
  """
  @spec start(Path.t(), String.t(), Path.t(), boolean(), [String.t()]) :: tracking() | nil
  def start(workdir, task_id, dir, new?, exclude) do
    file = base_file(workdir, task_id)

    with {:ok, base, exclude} <- base(file, new?, exclude),
         {:ok, start} <- snapshot(dir, exclude) do
      base = base || start
      if new?, do: File.write!(file, Jason.encode!(%{"base" => base, "exclude" => exclude}))
      %{base: base, start: start, exclude: exclude}
    else
      _no_base_or_snapshot -> nil
    end
  end

  @doc """
  What a stage changed, from where it started (`start/5`): `diff/4` plus
  `"task_files"`, the files changed since the task's base.
  """
  @spec report(Path.t(), tracking()) :: map() | nil
  def report(dir, %{base: base, start: start, exclude: exclude}) do
    case snapshot(dir, exclude) do
      {:ok, now} -> dir |> diff(start, now) |> Map.put("task_files", files(dir, base, now))
      {:error, _message} -> nil
    end
  end

  @doc "The file that keeps a task's base snapshot, next to its worktree."
  @spec base_file(Path.t(), String.t()) :: Path.t()
  def base_file(workdir, task_id), do: Path.join([workdir, "worktrees", task_id <> ".json"])

  defp base(_file, true, exclude), do: {:ok, nil, exclude}

  defp base(file, false, _exclude) do
    with {:ok, body} <- File.read(file),
         {:ok, %{"base" => base, "exclude" => exclude}} <- Jason.decode(body) do
      {:ok, base, exclude}
    end
  end

  @doc "The tree of `dir`'s files now, leaving out the `exclude` paths."
  @spec snapshot(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def snapshot(dir, exclude) do
    index = Path.join(System.tmp_dir!(), "cp-index-#{System.unique_integer([:positive])}")

    try do
      # git looks upwards for a repository: a directory that is not a
      # repository's root would snapshot the enclosing one.
      with {:ok, "\n"} <- git(dir, ["rev-parse", "--show-prefix"]),
           {:ok, real_index} <- git(dir, ["rev-parse", "--git-path", "index"]) do
        # Starting from the real index lets git skip hashing unchanged files.
        _copied = File.cp(Path.expand(String.trim(real_index), dir), index)
        env = [{"GIT_INDEX_FILE", index}]
        pathspec = ["--", "." | Enum.map(exclude, &":(exclude)#{&1}")]

        with {:ok, _added} <- git(dir, ["add", "--all" | pathspec], env),
             {:ok, tree} <- git(dir, ["write-tree"], env) do
          {:ok, String.trim(tree)}
        end
      else
        {:ok, _prefix} -> {:error, "#{dir} não é a raiz de um repositório git"}
        {:error, message} -> {:error, message}
      end
    after
      File.rm(index)
    end
  end

  @doc """
  The changes from tree `from` to tree `to`: `%{"files" => [%{"path", "added",
  "removed"}], "patch", "truncated"}` (`added` and `removed` are `nil` for a
  binary file). Option `:patch_bytes` limits the patch (default 200 KB).
  """
  @spec diff(Path.t(), String.t(), String.t(), keyword()) :: map()
  def diff(dir, from, to, opts \\ []) do
    limit = Keyword.get(opts, :patch_bytes, @patch_bytes)
    {:ok, numstat} = git(dir, ["diff", "--no-renames", "--numstat", from, to])
    {:ok, patch} = git(dir, ["diff", "--no-renames", from, to])
    truncated = byte_size(patch) > limit

    %{
      "files" => numstat |> String.split("\n", trim: true) |> Enum.map(&file/1),
      "patch" => if(truncated, do: cut(patch, limit), else: patch),
      "truncated" => truncated
    }
  end

  @doc "Only the files changed from tree `from` to tree `to`, as in `diff/4`."
  @spec files(Path.t(), String.t(), String.t()) :: [map()]
  def files(dir, from, to) do
    {:ok, numstat} = git(dir, ["diff", "--no-renames", "--numstat", from, to])
    numstat |> String.split("\n", trim: true) |> Enum.map(&file/1)
  end

  defp file(line) do
    [added, removed, path] = String.split(line, "\t", parts: 3)
    %{"path" => path, "added" => count(added), "removed" => count(removed)}
  end

  defp count("-"), do: nil
  defp count(number), do: String.to_integer(number)

  # At the last whole line within the limit.
  defp cut(patch, limit) do
    head = binary_part(patch, 0, limit)

    case :binary.matches(head, "\n") do
      [] -> ""
      matches -> binary_part(head, 0, elem(List.last(matches), 0) + 1)
    end
  end

  defp git(dir, args, env \\ []) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
