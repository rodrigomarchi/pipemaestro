defmodule PipeMaestroRunner.Workspace do
  @moduledoc """
  Where a job runs.

    * A job with no `directory` runs in the runner's workdir.
    * A job with a `directory` and a `worktree` (a task's stage, in a git
      repository) runs in a git worktree of that directory, one per task, at
      `<workdir>/worktrees/<task_id>` on the task's branch. The first stage
      creates it from the directory's current `HEAD`; later stages reuse it,
      so what one stage leaves behind is there for the next. The developer's
      own checkout is never touched.
    * A job with a `directory` and no `worktree` runs in the directory itself.
  """

  alias PipeMaestroProtocol.Job

  @doc """
  Prepares and returns the working directory for `job`, given the runner's
  `root` (where its code directories are) and `workdir`. When it has just
  created a worktree, it also returns the directory the worktree came from,
  so the worktree can be set up (`PipeMaestroRunner.Setup`); otherwise
  `nil`.
  """
  @spec prepare(Job.t(), Path.t() | nil, Path.t()) ::
          {:ok, Path.t(), Path.t() | nil} | {:error, String.t()}
  def prepare(%Job{directory: nil}, _root, workdir), do: {:ok, workdir, nil}

  def prepare(%Job{}, nil, _workdir),
    do: {:error, "Este runner não tem diretório raiz configurado (runner.start --root)."}

  def prepare(%Job{directory: directory} = job, root, workdir) do
    source = Path.join(root, directory)

    cond do
      not File.dir?(source) ->
        {:error, "O diretório #{directory} não existe em #{root}."}

      is_nil(job.worktree) ->
        {:ok, source, nil}

      true ->
        worktree(source, job.worktree, workdir)
    end
  end

  defp worktree(source, %{"task_id" => task_id, "branch" => branch}, workdir) do
    path = Path.join([workdir, "worktrees", task_id])

    cond do
      File.dir?(path) ->
        {:ok, path, nil}

      not repository_root?(source) ->
        {:error, "O diretório #{Path.basename(source)} não é a raiz de um repositório git."}

      true ->
        File.mkdir_p!(Path.dirname(path))
        add_worktree(source, path, branch)
    end
  end

  # git looks for a repository upwards from the directory it is given: without
  # this check, a directory inside some other repository would get a worktree
  # (and a branch) of that other repository.
  defp repository_root?(source) do
    git(source, ["rev-parse", "--show-prefix"]) == {:ok, "\n"}
  end

  # A new branch from HEAD; if the branch is already there (a worktree that was
  # removed by hand), the worktree checks it out again.
  defp add_worktree(source, path, branch) do
    result =
      case git(source, ["worktree", "add", "-b", branch, path, "HEAD"]) do
        {:error, output} ->
          if output =~ "already exists",
            do: git(source, ["worktree", "add", path, branch]),
            else: {:error, output}

        ok ->
          ok
      end

    case result do
      {:ok, _output} -> {:ok, path, source}
      {:error, output} -> {:error, "Não foi possível criar o worktree: #{output}"}
    end
  end

  @doc """
  Removes the worktree of task `task_id`, made from `directory` under `root`.
  """
  @spec remove_task_worktree(Path.t() | nil, Path.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def remove_task_worktree(root, workdir, task_id, directory) do
    path = Path.join([workdir, "worktrees", task_id])
    _base = File.rm(Path.join([workdir, "worktrees", task_id <> ".json"]))

    if root,
      do: remove_worktree(Path.join(root, directory), path),
      else: remove_worktree(workdir, path)
  end

  @doc """
  Removes a task's worktree, keeping its branch (and whatever was committed on
  it) in `source`. Removing a worktree that is not there is fine.
  """
  @spec remove_worktree(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def remove_worktree(source, path) do
    cond do
      not File.exists?(path) ->
        :ok

      match?({:ok, _}, git(source, ["worktree", "remove", "--force", path])) ->
        :ok

      true ->
        # Not a worktree git knows of (or its source is gone): the directory
        # goes, and git forgets the stale entry.
        case File.rm_rf(path) do
          {:ok, _removed} ->
            _pruned = git(source, ["worktree", "prune"])
            :ok

          {:error, reason, file} ->
            {:error, "Não foi possível apagar #{file}: #{:file.format_error(reason)}"}
        end
    end
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
