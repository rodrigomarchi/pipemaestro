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
    * A `scratch` job (an analysis) runs in a disposable worktree of its
      directory, at `<workdir>/scratch/<job_id>`, detached at the directory's
      `HEAD` and removed when the job ends (`remove_scratch/3`). Nothing it
      does reaches the directory.
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

      job.scratch == true ->
        scratch(source, job.id, workdir)

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

  defp scratch(source, job_id, workdir) do
    path = scratch_path(workdir, job_id)

    if repository_root?(source) do
      _stale = remove_worktree(source, path)
      # Worktrees deleted when the runner started (clear_scratch/1) leave
      # entries in the repository; git drops them here.
      _pruned = git(source, ["worktree", "prune"])
      File.mkdir_p!(Path.dirname(path))

      case git(source, ["worktree", "add", "--detach", path, "HEAD"]) do
        {:ok, _output} -> {:ok, path, source}
        {:error, output} -> {:error, "Não foi possível criar o worktree da análise: #{output}"}
      end
    else
      {:error,
       "A análise precisa de um repositório git: #{Path.basename(source)} não é a raiz de um."}
    end
  end

  @doc "Where the disposable worktree of `scratch` job `job_id` lives."
  @spec scratch_path(Path.t(), String.t()) :: Path.t()
  def scratch_path(workdir, job_id), do: Path.join([workdir, "scratch", job_id])

  @doc """
  Removes the disposable worktree of `job` (a `scratch` job), made from its
  directory under `root`. Removing one that is not there is fine.
  """
  @spec remove_scratch(Job.t(), Path.t() | nil, Path.t()) :: :ok | {:error, String.t()}
  def remove_scratch(%Job{id: id, directory: directory}, root, workdir) do
    path = scratch_path(workdir, id)
    source = if root && directory, do: Path.join(root, directory), else: workdir
    remove_worktree(source, path)
  end

  @doc """
  Deletes every disposable worktree left behind, as when the runner stopped in
  the middle of an analysis. git forgets their entries on its next prune.
  """
  @spec clear_scratch(Path.t()) :: :ok
  def clear_scratch(workdir) do
    _removed = File.rm_rf(Path.join(workdir, "scratch"))
    :ok
  end

  # git looks for a repository upwards from the directory it is given: without
  # this check, a directory inside some other repository would get a worktree
  # (and a branch) of that other repository.
  defp repository_root?(source) do
    git(source, ["rev-parse", "--show-prefix"]) == {:ok, "\n"}
  end

  # The task's branch, checked out again if it is here (a worktree removed);
  # otherwise a new branch, from the task's branch on origin if it was
  # pushed (another runner worked on it, or the branch was deleted here), or
  # from HEAD for a task that starts.
  defp add_worktree(source, path, branch) do
    # A worktree deleted by hand leaves an entry that would refuse the branch.
    _pruned = git(source, ["worktree", "prune"])

    result =
      if git(source, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch]) |> ok?(),
        do: git(source, ["worktree", "add", path, branch]),
        else: git(source, ["worktree", "add", "-b", branch, path, start_point(source, branch)])

    case result do
      {:ok, _output} -> {:ok, path, source}
      {:error, output} -> {:error, "Não foi possível criar o worktree: #{output}"}
    end
  end

  # The task's branch on origin, if it was pushed; otherwise origin's default
  # branch as origin has it now, not as the local checkout last saw it; HEAD
  # when there is no origin to ask.
  defp start_point(source, branch) do
    cond do
      remote_ok?(source, [
        "fetch",
        "--quiet",
        "origin",
        "refs/heads/#{branch}:refs/remotes/origin/#{branch}"
      ]) ->
        "origin/" <> branch

      remote_ok?(source, ["fetch", "--quiet", "origin"]) and default_branch(source) ->
        default_branch(source)

      true ->
        "HEAD"
    end
  end

  # origin/HEAD, learnt from origin when the clone never recorded it.
  defp default_branch(source) do
    with {:error, _unknown} <- git(source, ["rev-parse", "--abbrev-ref", "origin/HEAD"]),
         true <- remote_ok?(source, ["remote", "set-head", "origin", "--auto"]),
         {:ok, ref} <- git(source, ["rev-parse", "--abbrev-ref", "origin/HEAD"]) do
      String.trim(ref)
    else
      {:ok, ref} -> String.trim(ref)
      _none -> nil
    end
  end

  # Never a prompt for credentials: without them, origin is not there.
  defp remote_ok?(source, args) do
    match?(
      {_output, 0},
      System.cmd("git", ["-C", source | args],
        stderr_to_stdout: true,
        env: [{"GIT_TERMINAL_PROMPT", "0"}]
      )
    )
  end

  defp ok?({:ok, _output}), do: true
  defp ok?({:error, _output}), do: false

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
