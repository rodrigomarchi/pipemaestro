defmodule PipeMaestroRunner.RepoState do
  @moduledoc """
  What state a task's worktree is in, as git sees it, and the one change the
  runner makes to it on its own before a stage (`sync/2`).

  The agent may do anything in the worktree (commit, push, switch branches,
  stop in the middle of a merge), and so may people on the task's pull
  request. The runner does not guess nor fix that: it only fast-forwards the
  worktree to what origin has of the task's branch when that cannot lose or
  mix anything, and otherwise tells the agent what it found, in its prompt.
  """

  @typedoc "The worktree as git sees it."
  @type t :: %{
          branch: String.t() | nil,
          operation: String.t() | nil,
          lock: boolean(),
          remote: boolean(),
          ahead: non_neg_integer(),
          behind: non_neg_integer()
        }

  @operations [
    {"MERGE_HEAD", "um merge"},
    {"rebase-merge", "um rebase"},
    {"rebase-apply", "um rebase"},
    {"CHERRY_PICK_HEAD", "um cherry-pick"},
    {"REVERT_HEAD", "um revert"}
  ]

  @doc """
  Before a stage: fetches the task's `branch` from origin, fast-forwards the
  worktree `dir` when it is on that branch, clean, with nothing under way and
  only behind, and returns what the agent should know, in Markdown, or `nil`
  when there is nothing to tell.
  """
  @spec sync(Path.t(), String.t(), [{String.t(), String.t()}]) :: String.t() | nil
  def sync(dir, branch, env \\ []) do
    fetch(dir, branch, env)
    state = state(dir, branch)

    {state, forwarded} =
      if fast_forward?(dir, state, branch) and
           match?({:ok, _}, git(dir, ["merge", "--ff-only", "--quiet", "origin/" <> branch])),
         do: {state(dir, branch), state.behind},
         else: {state, 0}

    case notes(state, branch, forwarded) do
      [] -> nil
      notes -> "# Estado do repositório (visto pela plataforma)\n\n" <> Enum.join(notes, "\n")
    end
  end

  @doc """
  Fetches the task's `branch` from origin, never asking for credentials (but
  with the job's, `env`); `false` when it cannot.
  """
  @spec fetch(Path.t(), String.t(), [{String.t(), String.t()}]) :: boolean()
  def fetch(dir, branch, env \\ []) do
    match?(
      {:ok, _},
      git(
        dir,
        ["fetch", "--quiet", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"],
        env
      )
    )
  end

  @doc "The worktree `dir` as git sees it, against origin's copy of `branch`."
  @spec state(Path.t(), String.t()) :: t()
  def state(dir, branch) do
    remote =
      match?(
        {:ok, _},
        git(dir, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/" <> branch])
      )

    {ahead, behind} =
      with true <- remote,
           {:ok, counts} <-
             git(dir, ["rev-list", "--left-right", "--count", "HEAD...origin/" <> branch]),
           [ahead, behind] <- String.split(counts) do
        {String.to_integer(ahead), String.to_integer(behind)}
      else
        _none -> {0, 0}
      end

    %{
      branch: current_branch(dir),
      operation: operation(dir),
      lock: git_path_exists?(dir, "index.lock"),
      remote: remote,
      ahead: ahead,
      behind: behind
    }
  end

  @doc "The branch HEAD is on, or `nil` when it is detached."
  @spec current_branch(Path.t()) :: String.t() | nil
  def current_branch(dir) do
    case git(dir, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, branch} -> String.trim(branch)
      {:error, _detached} -> nil
    end
  end

  @doc "The git operation left under way in `dir` (a merge, a rebase...), named for a person, or `nil`."
  @spec operation(Path.t()) :: String.t() | nil
  def operation(dir) do
    Enum.find_value(@operations, fn {path, name} -> if git_path_exists?(dir, path), do: name end)
  end

  @doc "The files with unresolved conflicts in `dir`."
  @spec conflicted(Path.t()) :: [String.t()]
  def conflicted(dir) do
    case git(dir, ["diff", "--name-only", "--diff-filter=U"]) do
      {:ok, out} -> String.split(out, "\n", trim: true)
      {:error, _} -> []
    end
  end

  defp fast_forward?(dir, state, branch) do
    state.branch == branch and is_nil(state.operation) and not state.lock and state.behind > 0 and
      state.ahead == 0 and match?({:ok, _}, git(dir, ["diff", "--quiet", "HEAD"]))
  end

  defp notes(state, branch, forwarded) do
    [
      forwarded > 0 &&
        "- O origin tinha #{forwarded} commit(s) novo(s) na branch `#{branch}` (de uma pessoa no PR ou de outro agente); o worktree foi atualizado por fast-forward. Leve-os em conta.",
      state.branch != branch &&
        "- O HEAD está #{if state.branch, do: "na branch `#{state.branch}`", else: "solto (detached)"}, não na branch da tarefa, `#{branch}`. A entrega exige o trabalho em `#{branch}`.",
      state.operation &&
        "- Há #{state.operation} em andamento, deixado por uma execução anterior. Conclua ou aborte antes de seguir.",
      state.lock &&
        "- Existe um `index.lock` no repositório: um processo git anterior pode ter sido interrompido. Confira se nenhum git está rodando antes de removê-lo.",
      (state.behind > 0 and forwarded == 0) &&
        "- O origin tem #{state.behind} commit(s) na branch `#{branch}` que o worktree não tem#{if state.ahead > 0, do: " (e o worktree tem #{state.ahead} que o origin não tem)", else: ""}: veja com `git log HEAD..origin/#{branch}` e integre-os com merge, sem reescrever o que já está no origin. A entrega confere que a branch contém o origin."
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp git_path_exists?(dir, name) do
    case git(dir, ["rev-parse", "--git-path", name]) do
      {:ok, path} -> File.exists?(Path.expand(String.trim(path), dir))
      {:error, _} -> false
    end
  end

  defp git(dir, args, env \\ []) do
    case System.cmd("git", ["-C", dir | args],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"} | env]
         ) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
