defmodule PipeMaestroRunner.GateCache do
  @moduledoc """
  Gates that already passed on a tree (`PipeMaestroRunner.Gates`). A stage's
  gate often runs on the same code the previous stage's gate passed on (a
  review that changed nothing, the suite after it): run again, it would only
  spend the machine's time to say the same thing.

  The key is the working directory's tree as it is, tracked changes and new
  files included and ignored files left out, without the paths in `exclude`
  (the task's artifacts folder, what the setup copied), plus the gate's
  command and expectation. Only gates that passed are kept. A command that
  reads the remote (`fetch`, `pull`, `ls-remote`, `origin`) is never cached:
  its answer changes with the remote, not with the tree.

  The cache lives in the git dir of the checkout or worktree
  (`pipemaestro-gates.json`), so it is the worktree's own and outlives a
  restart of the runner. A directory outside git, or one its repository
  ignores, has no tree, and no cache.
  """

  @file_name "pipemaestro-gates.json"
  @kept 200
  @remote ~r/\b(fetch|pull|ls-remote|origin)\b/

  @typedoc "A cache to look gates up in and to keep them, or `nil` without a tree."
  @type t :: %{dir: Path.t(), tree: String.t(), file: Path.t()} | nil

  @doc """
  The cache of `dir` as its tree is now, leaving `exclude` (paths relative
  to `dir`) out of the key; `nil` when `dir` is not in git.
  """
  @spec open(Path.t(), [String.t()]) :: t()
  def open(dir, exclude \\ []) do
    with {:ok, index} <- git(dir, ["rev-parse", "--path-format=absolute", "--git-path", "index"]),
         false <- ignored?(dir),
         {:ok, file} <-
           git(dir, ["rev-parse", "--path-format=absolute", "--git-path", @file_name]),
         {:ok, tree} <- tree(dir, index, exclude) do
      %{dir: dir, tree: tree, file: file}
    else
      _no_tree -> nil
    end
  end

  @doc "Whether a gate with `command` may be taken from the cache and kept in it."
  @spec cacheable?(String.t()) :: boolean()
  def cacheable?(command), do: not Regex.match?(@remote, command)

  @doc """
  When the gate already passed on this tree, how: `%{"at" => ISO 8601,
  "exit_code" => integer}`; `nil` otherwise.
  """
  @spec lookup(t(), map()) :: %{String.t() => term()} | nil
  def lookup(nil, _gate), do: nil

  def lookup(cache, gate) do
    if cacheable?(gate["command"]), do: Map.get(read(cache.file), key(cache, gate))
  end

  @doc "Keeps the gates of `results` that passed, against the cache's tree."
  @spec remember(t(), [map()]) :: :ok
  def remember(nil, _results), do: :ok

  def remember(cache, results) do
    passed =
      for %{"passed" => true, "command" => command} = gate <- results,
          cacheable?(command),
          do:
            {key(cache, gate),
             %{
               "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
               "exit_code" => gate["exit_code"]
             }}

    if passed != [] do
      entries =
        cache.file
        |> read()
        |> Map.merge(Map.new(passed))
        |> Enum.sort_by(fn {_key, entry} -> entry["at"] end, :desc)
        |> Enum.take(@kept)
        |> Map.new()

      File.write(cache.file, JSON.encode!(entries))
    end

    :ok
  end

  @doc "The tree the cache is keyed on, abbreviated, for a person to read."
  @spec short_tree(t()) :: String.t()
  def short_tree(%{tree: tree}), do: String.slice(tree, 0, 12)

  defp key(cache, gate), do: Enum.join([cache.tree, gate["expect"], gate["command"]], "\n")

  defp read(file) do
    with {:ok, text} <- File.read(file),
         {:ok, %{} = entries} <- JSON.decode(text) do
      for {key, %{"at" => _} = entry} <- entries, into: %{}, do: {key, entry}
    else
      _missing_or_unreadable -> %{}
    end
  end

  # The tree of the working directory as it is: a copy of the real index
  # (whose stat cache spares hashing what did not change), every change
  # added to it, the excluded paths taken out.
  defp tree(dir, index, exclude) do
    copy = Path.join(System.tmp_dir!(), "pipemaestro-gates-#{System.unique_integer([:positive])}")
    _copied = File.cp(index, copy)
    env = [{"GIT_INDEX_FILE", copy}]

    try do
      with {:ok, _} <- git(dir, ["add", "--all"], env),
           {:ok, _} <- untrack(dir, exclude, env) do
        git(dir, ["write-tree"], env)
      end
    after
      File.rm(copy)
    end
  end

  # A directory the repository around it ignores is not in its tree: what
  # changes in it would never change the key.
  defp ignored?(dir), do: match?({:ok, _}, git(dir, ["check-ignore", "-q", "."]))

  defp untrack(_dir, [], _env), do: {:ok, ""}

  defp untrack(dir, exclude, env),
    do: git(dir, ["rm", "-r", "-q", "--cached", "--ignore-unmatch", "--" | exclude], env)

  defp git(dir, args, env \\ []) do
    case System.cmd("git", ["-C", dir | args],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"} | env]
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
