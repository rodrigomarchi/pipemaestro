defmodule PipeMaestro.Jobs.Files do
  @moduledoc """
  The files a job leaves for people to see: what the agent copied to
  `CP_FILES_DIR` (screenshots, reports, CSVs), which its runner sends one by
  one when the job ends (`PipeMaestroProtocol.JobFiles`).

  They are kept in the database (`PipeMaestro.Jobs.JobFile`), within the
  protocol's limits per file, per job and in number, and go away with their
  job. Listings never load the content; only a download does.

  The workspace sets the rest (ADR 0054): a quota of MiB its files that still
  have content may take (`workspace_usage/1`), past which an upload is refused
  and counted on the job (`files_refused_quota`), and a retention in days past
  which a file loses its content but keeps its name (`prune/2`).
  """
  import Ecto.Query

  alias PipeMaestro.Jobs.{Job, JobFile}
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks.{StageRun, Task}
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroProtocol.JobFiles

  @images ~w(image/png image/jpeg image/gif image/webp)

  @typedoc "Why a file was not kept."
  @type store_error :: :not_found | :invalid_path | :too_large | :quota_exceeded

  @mib 1_048_576

  @doc """
  Keeps `content` as the file `path` of the runner's job `job_id`, replacing
  the one already at that path. A job of another runner, or one that does not
  exist, is `:not_found`; a path `PipeMaestroProtocol.JobFiles.valid_path?/1`
  refuses is `:invalid_path`; a file, or a job's files, past the limits is
  `:too_large`; one that would take the workspace's files past its quota is
  `:quota_exceeded`, and the job counts it in `files_refused_quota`.
  """
  @spec store(Runner.t(), String.t(), String.t(), binary()) ::
          {:ok, JobFile.t()} | {:error, store_error()}
  def store(%Runner{id: runner_id}, job_id, path, content) when is_binary(content) do
    with {:ok, id} <- cast_id(job_id),
         true <- JobFiles.valid_path?(path) || {:error, :invalid_path},
         true <- byte_size(content) <= JobFiles.max_file_bytes() || {:error, :too_large} do
      fn -> store_locked(id, runner_id, path, content) end
      |> Repo.transact()
      |> count_refusal(id)
    end
  end

  defp store_locked(id, runner_id, path, content) do
    with %Job{} = job <- lock_job(id, runner_id) || {:error, :not_found},
         :ok <- within_job_limits(job.id, path, byte_size(content)),
         :ok <- within_quota(job, path, byte_size(content)) do
      insert(job, path, content)
    end
  end

  # The refusal is counted once the transaction that refused it is over.
  defp count_refusal({:error, :quota_exceeded} = error, job_id) do
    {1, _} =
      Repo.update_all(from(j in Job, where: j.id == ^job_id), inc: [files_refused_quota: 1])

    error
  end

  defp count_refusal(result, _job_id), do: result

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # The job's row stays locked until the file is in, so two files sent at
  # once cannot both pass the limits.
  defp lock_job(id, runner_id),
    do:
      Repo.one(
        from j in Job, where: j.id == ^id and j.runner_id == ^runner_id, lock: "FOR UPDATE"
      )

  defp within_job_limits(job_id, path, size) do
    {count, total} =
      Repo.one(
        from f in JobFile,
          where: f.job_id == ^job_id and f.path != ^path,
          select: {count(f.id), coalesce(sum(f.byte_size), 0)}
      )

    if count + 1 <= JobFiles.max_files() and to_integer(total) + size <= JobFiles.max_job_bytes(),
      do: :ok,
      else: {:error, :too_large}
  end

  # One upload per workspace checks its quota at a time (a lock for the
  # transaction), so two at once cannot both pass it. Without a quota,
  # nothing is locked nor summed.
  defp within_quota(%Job{workspace_id: workspace_id, id: job_id}, path, size) do
    case Repo.one(
           from w in Workspace, where: w.id == ^workspace_id, select: w.job_files_quota_mib
         ) do
      nil ->
        :ok

      quota_mib ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "job_files_quota:" <> workspace_id
        ])

        used =
          Repo.one(
            from f in JobFile,
              where:
                f.workspace_id == ^workspace_id and is_nil(f.pruned_at) and
                  not (f.job_id == ^job_id and f.path == ^path),
              select: coalesce(sum(f.byte_size), 0)
          )

        if to_integer(used) + size <= quota_mib * @mib, do: :ok, else: {:error, :quota_exceeded}
    end
  end

  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value

  defp insert(job, path, content) do
    now = DateTime.utc_now(:second)

    file = %JobFile{
      workspace_id: job.workspace_id,
      job_id: job.id,
      stage_run_id: job.stage_run_id,
      path: path,
      content: content,
      content_type: MIME.from_path(path),
      byte_size: byte_size(content),
      sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower),
      inserted_at: now,
      updated_at: now
    }

    file
    |> Repo.insert(
      on_conflict:
        {:replace, [:content, :content_type, :byte_size, :sha256, :pruned_at, :updated_at]},
      conflict_target: [:job_id, :path],
      returning: [:id, :inserted_at]
    )
    |> case do
      {:ok, stored} -> {:ok, %{stored | content: nil}}
      {:error, _changeset} = error -> error
    end
  end

  @doc """
  What the workspace's files take: the bytes of those that still have their
  content, and its quota in bytes (`nil` without one).
  """
  @spec workspace_usage(Workspace.t()) :: %{
          bytes: non_neg_integer(),
          quota_bytes: pos_integer() | nil
        }
  def workspace_usage(%Workspace{id: workspace_id} = workspace) do
    bytes =
      Repo.one(
        from f in JobFile,
          where: f.workspace_id == ^workspace_id and is_nil(f.pruned_at),
          select: coalesce(sum(f.byte_size), 0)
      )

    %{bytes: to_integer(bytes), quota_bytes: quota_bytes(workspace)}
  end

  @doc "The workspace's quota of files in bytes, or `nil` without one."
  @spec quota_bytes(Workspace.t()) :: pos_integer() | nil
  def quota_bytes(%Workspace{job_files_quota_mib: nil}), do: nil
  def quota_bytes(%Workspace{job_files_quota_mib: quota_mib}), do: quota_mib * @mib

  @doc """
  Takes the content of the files older than their workspace's
  `job_files_retention_days` (from when they arrived), as of `now`: each keeps
  its path, size and type, and gets `pruned_at`. Workspaces without a
  retention keep every file. At most `:batch` (default 500) files per call;
  returns how many it emptied.
  """
  @spec prune(DateTime.t(), keyword()) :: non_neg_integer()
  def prune(now, opts \\ []) do
    batch = Keyword.get(opts, :batch, 500)
    now = DateTime.truncate(now, :second)

    expired =
      from f in JobFile,
        join: w in Workspace,
        on: w.id == f.workspace_id,
        where:
          is_nil(f.pruned_at) and not is_nil(w.job_files_retention_days) and
            f.inserted_at <
              fragment(
                "? - make_interval(days => ?)",
                type(^now, :utc_datetime),
                w.job_files_retention_days
              ),
        select: f.id,
        limit: ^batch

    {count, _} =
      Repo.update_all(from(f in JobFile, where: f.id in subquery(expired)),
        set: [content: nil, pruned_at: now]
      )

    count
  end

  @doc "A stage run's files, by path, without their content."
  @spec list_for_stage_run(StageRun.t()) :: [JobFile.t()]
  def list_for_stage_run(%StageRun{id: id}),
    do: Repo.all(from f in JobFile, where: f.stage_run_id == ^id, order_by: f.path)

  @doc "A task's files, without their content, by stage run id, each list by path."
  @spec list_for_task(Task.t()) :: %{Ecto.UUID.t() => [JobFile.t()]}
  def list_for_task(%Task{id: id}) do
    from(f in JobFile,
      join: r in StageRun,
      on: r.id == f.stage_run_id,
      where: r.task_id == ^id,
      order_by: f.path
    )
    |> Repo.all()
    |> Enum.group_by(& &1.stage_run_id)
  end

  @doc """
  The workspace's file `id`, with its content, or `nil`. A file the
  retention emptied comes without content (`JobFile.pruned?/1`).
  """
  @spec get_for_download(Workspace.t(), String.t()) :: JobFile.t() | nil
  def get_for_download(%Workspace{id: workspace_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.one(
          from f in JobFile,
            where: f.id == ^uuid and f.workspace_id == ^workspace_id,
            select: struct(f, ^(JobFile.__schema__(:fields) ++ [:content]))
        )

      :error ->
        nil
    end
  end

  @doc "Whether the file is a raster image, which the browser may show inline."
  @spec image?(JobFile.t()) :: boolean()
  def image?(%JobFile{content_type: type}), do: type in @images

  @doc "The limits on a job's files (`PipeMaestroProtocol.JobFiles`)."
  @spec limits() :: %{
          max_file_bytes: pos_integer(),
          max_job_bytes: pos_integer(),
          max_files: pos_integer()
        }
  def limits do
    %{
      max_file_bytes: JobFiles.max_file_bytes(),
      max_job_bytes: JobFiles.max_job_bytes(),
      max_files: JobFiles.max_files()
    }
  end
end
