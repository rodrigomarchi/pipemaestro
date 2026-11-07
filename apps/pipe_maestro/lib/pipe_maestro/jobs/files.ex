defmodule PipeMaestro.Jobs.Files do
  @moduledoc """
  The files a job leaves for people to see: what the agent copied to
  `CP_FILES_DIR` (screenshots, reports, CSVs), which its runner sends one by
  one when the job ends (`PipeMaestroProtocol.JobFiles`).

  They are kept in the database (`PipeMaestro.Jobs.JobFile`), within the
  protocol's limits per file, per job and in number, and go away with their
  job. Listings never load the content; only a download does.
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
  @type store_error :: :not_found | :invalid_path | :too_large

  @doc """
  Keeps `content` as the file `path` of the runner's job `job_id`, replacing
  the one already at that path. A job of another runner, or one that does not
  exist, is `:not_found`; a path `PipeMaestroProtocol.JobFiles.valid_path?/1`
  refuses is `:invalid_path`; a file, or a job's files, past the limits is
  `:too_large`.
  """
  @spec store(Runner.t(), String.t(), String.t(), binary()) ::
          {:ok, JobFile.t()} | {:error, store_error()}
  def store(%Runner{id: runner_id}, job_id, path, content) when is_binary(content) do
    with {:ok, id} <- cast_id(job_id),
         true <- JobFiles.valid_path?(path) || {:error, :invalid_path},
         true <- byte_size(content) <= JobFiles.max_file_bytes() || {:error, :too_large} do
      Repo.transact(fn ->
        with %Job{} = job <- lock_job(id, runner_id) || {:error, :not_found},
             :ok <- within_job_limits(job.id, path, byte_size(content)) do
          insert(job, path, content)
        end
      end)
    end
  end

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
      on_conflict: {:replace, [:content, :content_type, :byte_size, :sha256, :updated_at]},
      conflict_target: [:job_id, :path],
      returning: [:id, :inserted_at]
    )
    |> case do
      {:ok, stored} -> {:ok, %{stored | content: nil}}
      {:error, _changeset} = error -> error
    end
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

  @doc "The workspace's file `id`, with its content, or `nil`."
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
