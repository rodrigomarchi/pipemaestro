defmodule PipeMaestro.Jobs do
  @moduledoc """
  Jobs: a prompt a workspace member sends to one of the workspace's runners,
  which runs it with the agent CLI and reports back events and the outcome.

  Every change is broadcast on PubSub (`subscribe/1`):

    * `{:job, id}` gets `{:job_updated, job}` and `{:job_event, event}`.
    * `{:workspace, id}` gets `{:job_updated, job}` for the workspace's jobs.
    * `{:runner, id}` gets what must reach that runner: `{:job_assign, job}` and
      `{:job_cancel, job_id}`. The runner's channel subscribes to it.

  The functions a runner calls take the runner first and only touch that
  runner's jobs.
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Insights
  alias PipeMaestro.Jobs.{Event, Job}
  alias PipeMaestro.Jobs.Telemetry, as: JobTelemetry
  alias PipeMaestro.{Projects, Repo, Runners}
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroProtocol.Telemetry

  @pubsub PipeMaestro.PubSub
  # What a runner announces to run a job in a disposable worktree.
  @scratch "scratch"
  @list_limit 100

  @typedoc "What a PubSub subscription is about."
  @type subject :: {:job, Ecto.UUID.t()} | {:workspace, Ecto.UUID.t()} | {:runner, Ecto.UUID.t()}

  @doc "Subscribes the calling process to a job's, workspace's or runner's job messages."
  @spec subscribe(subject()) :: :ok | {:error, term()}
  def subscribe(subject), do: Phoenix.PubSub.subscribe(@pubsub, topic(subject))

  defp topic({:job, id}), do: "jobs:job:" <> id
  defp topic({:workspace, id}), do: "jobs:workspace:" <> id
  defp topic({:runner, id}), do: "jobs:runner:" <> id

  @doc """
  Sends a message to the channel of the runner `runner_id` (subscribed to
  `{:runner, id}`), for what other contexts ask of a runner.
  """
  @spec tell_runner(Ecto.UUID.t(), term()) :: :ok | {:error, term()}
  def tell_runner(runner_id, message), do: broadcast({:runner, runner_id}, message)

  defp broadcast(subject, message), do: Phoenix.PubSub.broadcast(@pubsub, topic(subject), message)

  # ── Members ───────────────────────────────────────────────────────────────

  @doc "A changeset for the new-job form."
  @spec change_job(map()) :: Ecto.Changeset.t()
  def change_job(attrs \\ %{}), do: Job.create_changeset(%Job{}, attrs)

  @doc """
  Creates a job a member sends on its own for one of the workspace's projects
  (`project_id`) and hands it to the project's runner. It runs in a
  disposable worktree of the project's directory, set up as the project says
  (`PipeMaestro.Projects.scratch_context/1`), so the directory must be git and
  the runner able to make one. With the runner offline, the job waits for it
  (`queued_for_runner/1`).
  """
  @spec create_job(User.t(), Workspace.t(), map()) ::
          {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def create_job(%User{} = user, %Workspace{} = workspace, attrs) do
    %Job{workspace_id: workspace.id, created_by_user_id: user.id}
    |> Job.create_changeset(attrs)
    |> put_project(workspace)
    |> insert_and_assign()
  end

  @doc """
  Why a project cannot take a job on its own now, or `:ok`: it is gone, it
  has no runner, its runner no longer offers the directory, the directory is
  not git or the runner cannot make a disposable worktree.
  """
  @spec project_ready(Project.t() | nil) :: :ok | {:error, String.t()}
  def project_ready(nil), do: {:error, "o projeto não existe mais"}

  def project_ready(%Project{runner: %Runner{revoked_at: nil} = runner} = project) do
    case Runner.directory(runner, project.directory) do
      nil ->
        {:error, "o runner não oferece mais a pasta do projeto"}

      %{"git" => true} ->
        if scratch?(runner), do: :ok, else: {:error, "o runner precisa ser atualizado"}

      _not_git ->
        {:error, "a pasta do projeto não é um repositório git"}
    end
  end

  def project_ready(%Project{}), do: {:error, "o projeto precisa de um runner"}

  defp scratch?(runner), do: Runners.capable?(runner, @scratch)

  defp put_project(changeset, workspace) do
    with id when not is_nil(id) <- Ecto.Changeset.get_field(changeset, :project_id),
         project = Projects.get_project(workspace, id),
         :ok <- project_ready(project) do
      changeset
      |> Ecto.Changeset.put_change(:runner_id, project.runner_id)
      |> Ecto.Changeset.put_change(:context, Projects.scratch_context(project))
    else
      nil -> changeset
      {:error, message} -> Ecto.Changeset.add_error(changeset, :project_id, message)
    end
  end

  @doc """
  Creates a job the control plane builds itself (a proposal) for one of the
  workspace's runners and hands it to that runner. A revoked runner or one
  from another workspace is refused. `context` is the wire form of the job's
  context (`PipeMaestroProtocol.Job`), plus any key of the control plane's
  own, which never reaches the runner.
  """
  @spec create_runner_job(User.t(), Workspace.t(), map(), map()) ::
          {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def create_runner_job(%User{} = user, %Workspace{} = workspace, attrs, context \\ %{}) do
    %Job{workspace_id: workspace.id, created_by_user_id: user.id, context: context}
    |> Job.runner_changeset(attrs)
    |> validate_runner(workspace)
    |> insert_and_assign()
  end

  defp insert_and_assign(changeset) do
    with {:ok, job} <- Repo.insert(changeset) do
      job = preload(job)
      broadcast({:workspace, job.workspace_id}, {:job_updated, job})
      broadcast({:runner, job.runner_id}, {:job_assign, job})
      {:ok, job}
    end
  end

  @doc """
  Creates the job that runs one attempt of a task's stage and hands it to the
  task's runner. `context` is the wire form of the job's context
  (`PipeMaestroProtocol.Job`).
  """
  @spec create_stage_job(map()) :: Job.t()
  def create_stage_job(attrs) do
    job =
      %Job{}
      |> Ecto.Changeset.change(
        Map.take(attrs, [
          :workspace_id,
          :runner_id,
          :project_id,
          :created_by_user_id,
          :stage_run_id,
          :prompt,
          :context
        ])
      )
      |> Repo.insert!()
      |> preload()

    broadcast({:workspace, job.workspace_id}, {:job_updated, job})
    broadcast({:runner, job.runner_id}, {:job_assign, job})
    job
  end

  defp validate_runner(changeset, workspace) do
    Ecto.Changeset.validate_change(changeset, :runner_id, fn :runner_id, runner_id ->
      if Repo.exists?(
           from r in Runner,
             where:
               r.id == ^runner_id and r.workspace_id == ^workspace.id and is_nil(r.revoked_at)
         ),
         do: [],
         else: [runner_id: "não é um runner ativo deste workspace"]
    end)
  end

  @doc "The workspace's most recent jobs, newest first."
  @spec list_jobs(Workspace.t()) :: [Job.t()]
  def list_jobs(%Workspace{id: workspace_id}) do
    Repo.all(
      from j in Job,
        where: j.workspace_id == ^workspace_id,
        order_by: [desc: j.inserted_at, desc: j.id],
        limit: @list_limit,
        preload: [:runner, :created_by_user, :project]
    )
  end

  @doc """
  How busy the workspace's runners are: for each runner with unfinished jobs,
  how many are running and how many wait.
  """
  @spec load_by_runner(Workspace.t()) :: %{
          Ecto.UUID.t() => %{running: non_neg_integer(), queued: non_neg_integer()}
        }
  def load_by_runner(%Workspace{id: workspace_id}) do
    from(j in Job,
      where: j.workspace_id == ^workspace_id and j.status in [:queued, :running],
      group_by: [j.runner_id, j.status],
      select: {j.runner_id, j.status, count(j.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {runner_id, status, count}, acc ->
      acc
      |> Map.put_new(runner_id, %{running: 0, queued: 0})
      |> put_in([runner_id, status], count)
    end)
  end

  @doc "One of the workspace's jobs. Raises when it is not there."
  @spec get_job!(Workspace.t(), Ecto.UUID.t()) :: Job.t()
  def get_job!(%Workspace{id: workspace_id}, id) do
    Job
    |> Repo.get_by!(id: id, workspace_id: workspace_id)
    |> preload()
  end

  @doc "A job's events in the order they happened."
  @spec list_events(Job.t()) :: [Event.t()]
  def list_events(%Job{id: job_id}) do
    Repo.all(from e in Event, where: e.job_id == ^job_id, order_by: e.seq)
  end

  @doc """
  Asks for a job to stop. A queued job is canceled at once; a running one is
  marked and its runner told to stop it, and the runner reports the end.
  """
  @spec request_cancel(Job.t()) :: {:ok, Job.t()} | {:error, :finished}
  def request_cancel(%Job{status: :queued} = job) do
    job = update!(job, status: :canceled, finished_at: now(), cancel_requested_at: now())
    broadcast({:runner, job.runner_id}, {:job_cancel, job.id})
    finished(job)
    {:ok, job}
  end

  def request_cancel(%Job{status: :running} = job) do
    job = update!(job, cancel_requested_at: now())
    broadcast({:runner, job.runner_id}, {:job_cancel, job.id})
    {:ok, job}
  end

  def request_cancel(%Job{}), do: {:error, :finished}

  @doc """
  Ends a job without waiting for its runner, which is offline: it is
  canceled now, with `error` saying why, and what depends on it moves on. If
  the runner comes back still running it, `ended_among/2` tells it to stop;
  a result it sends later is ignored.
  """
  @spec abandon(Job.t(), String.t()) :: {:ok, Job.t()} | {:error, :finished}
  def abandon(%Job{status: :queued} = job, _error), do: request_cancel(job)

  def abandon(%Job{status: :running} = job, error) do
    job =
      job
      |> update!(status: :canceled, error: error, finished_at: now(), cancel_requested_at: now())
      |> summarize()

    notify(job)
    finished(job)
    {:ok, job}
  end

  def abandon(%Job{}, _error), do: {:error, :finished}

  @doc """
  Of the jobs a runner says it is running, the ones that already ended here
  (abandoned while it was offline): it is told to cancel them.
  """
  @spec ended_among(Runner.t(), [String.t()]) :: [String.t()]
  def ended_among(%Runner{id: runner_id}, running_job_ids) do
    Repo.all(
      from j in Job,
        where:
          j.runner_id == ^runner_id and j.id in ^valid_ids(running_job_ids) and
            j.status not in [:running, :queued],
        select: j.id
    )
  end

  # ── Runners ───────────────────────────────────────────────────────────────

  @doc """
  The last `limit` jobs `runner` finished in `workspace`, the latest first, with
  their stage and task. A job canceled before it started never ran on the
  runner and is left out.
  """
  @spec recent_for_runner(Workspace.t(), Runner.t(), pos_integer()) :: [Job.t()]
  def recent_for_runner(%Workspace{id: workspace_id}, %Runner{id: runner_id}, limit \\ 10) do
    Repo.all(
      from j in Job,
        where:
          j.workspace_id == ^workspace_id and j.runner_id == ^runner_id and
            j.status in ^Job.finished_statuses() and not is_nil(j.started_at),
        order_by: [desc: j.finished_at, desc: j.id],
        limit: ^limit,
        preload: [stage_run: :task]
    )
  end

  @doc "The runner's unfinished jobs: the running ones, then those waiting, oldest first."
  @spec active_for_runner(Runner.t()) :: [Job.t()]
  def active_for_runner(%Runner{id: runner_id}) do
    Repo.all(
      from j in Job,
        where: j.runner_id == ^runner_id and j.status in [:running, :queued],
        order_by: [desc: j.status == :running, asc: j.inserted_at, asc: j.id]
    )
  end

  @doc "The runner's jobs that still wait to start, oldest first."
  @spec queued_for_runner(Runner.t()) :: [Job.t()]
  def queued_for_runner(%Runner{id: runner_id}) do
    Repo.all(
      from j in Job,
        where: j.runner_id == ^runner_id and j.status == :queued,
        order_by: [asc: j.inserted_at, asc: j.id]
    )
  end

  @doc """
  Squares the runner's jobs with what it says it is running when it joins.
  A job marked running that the runner no longer runs lost its process (the
  runner restarted): it fails. Returns the queued jobs to hand over again.
  """
  @spec reconcile(Runner.t(), [String.t()]) :: [Job.t()]
  def reconcile(%Runner{id: runner_id} = runner, running_job_ids) do
    lost =
      Repo.all(
        from j in Job,
          where:
            j.runner_id == ^runner_id and j.status == :running and
              j.id not in ^valid_ids(running_job_ids)
      )

    for job <- lost do
      job
      |> update!(
        status: :failed,
        error: "O runner reiniciou durante a execução.",
        finished_at: now()
      )
      |> summarize()
      |> finished()
    end

    queued_for_runner(runner)
  end

  @doc "The runner started one of its queued jobs."
  @spec mark_started(Runner.t(), String.t()) ::
          {:ok, Job.t()} | {:error, :not_found | :not_queued}
  def mark_started(%Runner{} = runner, job_id) do
    with {:ok, job} <- fetch_for_runner(runner, job_id) do
      case job.status do
        :queued -> {:ok, update!(job, status: :running, started_at: now())}
        _other -> {:error, :not_queued}
      end
    end
  end

  @doc """
  Stores an event the runner reported for one of its jobs. An event already
  stored (same `seq`) is ignored. A `"rate_limit"` event is also kept on the
  runner (`PipeMaestro.Runners.record_rate_limit/2`): the limits are its
  account's.
  """
  @spec append_event(Runner.t(), String.t(), map()) ::
          {:ok, Event.t() | :duplicate} | {:error, :not_found | Ecto.Changeset.t()}
  def append_event(%Runner{} = runner, job_id, attrs) do
    with {:ok, job} <- fetch_for_runner(runner, job_id),
         {:ok, event} <- %Event{job_id: job.id} |> Event.changeset(attrs) |> apply_insert() do
      case insert_event(event) do
        {1, [stored]} ->
          :ok = keep_rate_limit(runner, stored)
          broadcast({:job, job.id}, {:job_event, stored})
          {:ok, stored}

        {0, []} ->
          {:ok, :duplicate}
      end
    end
  end

  defp keep_rate_limit(runner, %Event{type: "rate_limit", data: data}) do
    {:ok, _runner} = Runners.record_rate_limit(runner, data)
    :ok
  end

  defp keep_rate_limit(_runner, _event), do: :ok

  defp apply_insert(changeset), do: Ecto.Changeset.apply_action(changeset, :insert)

  # insert_all reports whether the row was new; Repo.insert with
  # `on_conflict: :nothing` cannot tell, since the id is generated client-side.
  defp insert_event(%Event{} = event) do
    row = %{
      id: Ecto.UUID.generate(),
      job_id: event.job_id,
      seq: event.seq,
      type: event.type,
      data: event.data,
      inserted_at: now()
    }

    Repo.insert_all(Event, [row],
      on_conflict: :nothing,
      conflict_target: [:job_id, :seq],
      returning: true
    )
  end

  @doc """
  Passes on what the agent of one of the runner's running jobs is writing to
  whoever watches the job (`{:job, id}` gets `{:job_delta, id, text}`). Not
  stored: the full message comes as an event.
  """
  @spec relay_delta(Runner.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def relay_delta(%Runner{} = runner, job_id, text) when is_binary(text) do
    case fetch_for_runner(runner, job_id) do
      {:ok, %Job{status: :running} = job} -> broadcast({:job, job.id}, {:job_delta, job.id, text})
      _missing_or_not_running -> {:error, :not_found}
    end
  end

  @doc """
  Stores the OpenTelemetry records the runner relayed for one of its jobs
  (`PipeMaestroProtocol.Telemetry`), finished or not: they may arrive
  after the job's end. Records the protocol does not know are skipped, and
  metric increments add up in the job's `telemetry_totals`. Whoever watches
  the job (`{:job, id}`) gets `{:job_telemetry, id}`. Returns how many were
  stored. Records of a job that already ended update its summary
  (`PipeMaestro.Insights.store_summary/1`).
  """
  @spec record_telemetry(Runner.t(), String.t(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def record_telemetry(%Runner{} = runner, job_id, records) when is_list(records) do
    with {:ok, job} <- fetch_for_runner(runner, job_id) do
      inserted_at = DateTime.utc_now()

      rows =
        records
        |> Enum.take(Telemetry.max_records())
        |> Enum.flat_map(&telemetry_row(&1, job, inserted_at))

      {count, _rows} = Repo.insert_all(JobTelemetry, rows)
      add_totals(job, rows)
      if count > 0 and not Job.active?(job), do: job.id |> get_job() |> summarize()
      if count > 0, do: broadcast({:job, job.id}, {:job_telemetry, job.id})
      {:ok, count}
    end
  end

  # A record the protocol knows, with a valid time, as a row; else nothing.
  defp telemetry_row(%{"name" => name, "at" => at} = record, job, inserted_at)
       when is_binary(at) do
    with true <- name in Telemetry.names(),
         {:ok, time, _offset} <- DateTime.from_iso8601(at) do
      attrs = if is_map(record["attrs"]), do: record["attrs"], else: %{}

      [
        %{
          id: Ecto.UUID.generate(),
          job_id: job.id,
          workspace_id: job.workspace_id,
          name: name,
          at: usec(time),
          attrs: Telemetry.record(name, at, attrs)["attrs"],
          inserted_at: inserted_at
        }
      ]
    else
      _unknown_or_bad_time -> []
    end
  end

  defp telemetry_row(_record, _job, _inserted_at), do: []

  defp usec(%DateTime{microsecond: {value, _precision}} = at), do: %{at | microsecond: {value, 6}}

  defp add_totals(job, rows) do
    increments = JobTelemetry.increments(rows)
    if increments != %{}, do: add_increments(job, increments)
    :ok
  end

  # The job's row is locked while its totals are read and written, so two
  # batches arriving at once both count.
  defp add_increments(job, increments) do
    Repo.transaction(fn ->
      current =
        Repo.one!(
          from j in Job, where: j.id == ^job.id, lock: "FOR UPDATE", select: j.telemetry_totals
        )

      totals = Map.merge(current || %{}, increments, fn _key, a, b -> a + b end)
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [telemetry_totals: totals])
    end)
  end

  @doc "A job's OpenTelemetry records, in the order they happened."
  @spec list_telemetry(Job.t()) :: [JobTelemetry.t()]
  def list_telemetry(%Job{id: job_id}) do
    Repo.all(from t in JobTelemetry, where: t.job_id == ^job_id, order_by: [asc: t.at, asc: t.id])
  end

  @doc """
  Records how one of the runner's jobs ended, and keeps the run's summary
  (`PipeMaestro.Insights.store_summary/1`).
  """
  @spec finish_job(Runner.t(), String.t(), map()) ::
          {:ok, Job.t()} | {:error, :not_found | :finished | Ecto.Changeset.t()}
  def finish_job(%Runner{} = runner, job_id, attrs) do
    with {:ok, job} <- fetch_for_runner(runner, job_id),
         true <- Job.active?(job) || {:error, :finished},
         {:ok, job} <- job |> Job.finish_changeset(attrs, now()) |> Repo.update() do
      job = summarize(job)
      notify(job)
      finished(job)
      {:ok, job}
    end
  end

  # Keeps the ended run's summary, read back on the job.
  defp summarize(%Job{} = job) do
    :ok = Insights.store_summary(job)
    job.id |> get_job() |> preload()
  end

  defp get_job(id), do: Repo.get!(Job, id)

  # A job that runs a task's stage moves its task along once it ends; the
  # analysis of a paused task's failure gives it its questionnaire; a task
  # proposal may become its task.
  defp finished(%Job{stage_run_id: nil, context: %{"proposal" => %{"kind" => "analysis"}}} = job),
    do: PipeMaestro.Tasks.analysis_finished(job)

  defp finished(%Job{stage_run_id: nil, context: %{"proposal" => %{"kind" => "task"}}} = job),
    do: PipeMaestro.Proposals.job_finished(job)

  defp finished(%Job{stage_run_id: nil}), do: :ok
  defp finished(%Job{} = job), do: PipeMaestro.Tasks.job_finished(job)

  @doc """
  Merges `changes` into a proposal's own context (`"proposal"`, see
  `PipeMaestro.Proposals`), under a lock on the job's row so no other write
  is lost, and tells whoever watches the job.
  """
  @spec update_proposal(Job.t(), map()) :: Job.t()
  def update_proposal(%Job{id: id}, changes) do
    {:ok, job} =
      Repo.transaction(fn ->
        job = Repo.one!(from j in Job, where: j.id == ^id, lock: "FOR UPDATE")
        context = Map.update(job.context, "proposal", changes, &Map.merge(&1, changes))
        job |> Ecto.Changeset.change(context: context) |> Repo.update!()
      end)

    job = preload(job)
    notify(job)
    job
  end

  defp fetch_for_runner(%Runner{id: runner_id}, job_id) do
    with {:ok, id} <- Ecto.UUID.cast(job_id),
         %Job{} = job <- Repo.get_by(Job, id: id, runner_id: runner_id) do
      {:ok, job}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp valid_ids(ids) do
    Enum.flat_map(ids, fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
  end

  defp update!(job, changes) do
    job = job |> Ecto.Changeset.change(changes) |> Repo.update!() |> preload()
    notify(job)
    job
  end

  defp notify(job) do
    broadcast({:job, job.id}, {:job_updated, job})
    broadcast({:workspace, job.workspace_id}, {:job_updated, job})
  end

  defp preload(job), do: Repo.preload(job, [:runner, :created_by_user, :project], force: true)

  defp now, do: DateTime.utc_now(:second)
end
