defmodule PipeMaestro.Tasks do
  @moduledoc """
  Tasks: a prompt worked through a pipeline, stage by stage, on one runner and
  in one of its directories.

  Each stage attempt is a `PipeMaestro.Tasks.StageRun` run as a job.
  When the job ends, `job_finished/1` applies the gate
  (`PipeMaestro.Tasks.Engine`): the next stage starts, the stage is
  tried again, or the task waits for a person (`awaiting_decision`). A person
  then retries the stage or moves to the next one, optionally with
  instructions, or cancels the task.

  A pause because a stage blocked or failed comes with questions for the
  person when there are any (`decision_questionnaire`,
  `PipeMaestro.Tasks.Questionnaire`): those the agent asked, or, on a
  failure, those of an analysis the platform asks the agent for by itself
  (`request_analysis/1`, `PipeMaestro.Proposals.AnalysisKind`). The person
  answers them (`answer/4`) and the next attempt gets the answers in its
  prompt; the manual decision stays available all along.

  A stage's job lost by its runner (a restart, an update, a crash) is not an
  attempt (`job_lost/1`): its run becomes `lost` and the stage runs again in
  the same attempt, up to `max_lost_requeues` times (config of
  `:pipe_maestro`, 3 by default); past that, the task waits for a person.

  A task's worktree stays on the runner after the task ends, until someone
  asks for it to go (`remove_worktree/1`): the runner's channel gets
  `{:worktree_remove, removal}` and the runner confirms
  (`worktree_removed/3`).

  Changes are broadcast on PubSub (`subscribe/1`): `{:task, id}` and
  `{:workspace, id}` get `{:task_updated, task}`, and `{:decisions, id}` gets
  `{:pending_decisions, count}`, the workspace's tasks waiting for a decision.
  `{:events, id}` gets `{:task_event, %{id, title, kind, reason}}` when a task
  starts waiting for a decision (`kind: :awaiting`) or ends (`:succeeded`,
  `:failed`, `:canceled`), for notifications; those events are also kept in
  the inbox of the task's people (`PipeMaestro.Notifications`), and every
  change tells the workspace's notification center
  (`PipeMaestro.Notifications.executions_changed/1`).
  """

  import Ecto.Query

  require Logger

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Audit
  alias PipeMaestro.Integrations
  alias PipeMaestro.Integrations.{LinkedRepo, Trigger}
  alias PipeMaestro.Jobs
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Notifications
  alias PipeMaestro.Pipelines
  alias PipeMaestro.Pipelines.{Pipeline, Prompt, Stage}
  alias PipeMaestro.Projects
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Proposals
  alias PipeMaestro.Proposals.AnalysisKind
  alias PipeMaestro.{Repo, Runners, RunnerTelemetry}
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks.{Contract, Decision, Engine, Questionnaire, StageRun, Task}
  alias PipeMaestro.Workspaces
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroProtocol.JobFiles

  @pubsub PipeMaestro.PubSub
  @list_limit 100
  @max_artifact_bytes 65_536
  # How long a decision may wait before it is overdue.
  @decision_hours 24
  # How many times a stage's attempt runs again after its job was lost.
  @max_lost_requeues 3

  @typedoc "What a PubSub subscription is about."
  @type subject ::
          {:task, Ecto.UUID.t()}
          | {:workspace, Ecto.UUID.t()}
          | {:decisions, Ecto.UUID.t()}
          | {:events, Ecto.UUID.t()}
          | :linked

  @doc "Subscribes the calling process to a task's or a workspace's task updates."
  @spec subscribe(subject()) :: :ok | {:error, term()}
  def subscribe({:task, id}), do: Phoenix.PubSub.subscribe(@pubsub, "tasks:task:" <> id)
  def subscribe({:workspace, id}), do: Phoenix.PubSub.subscribe(@pubsub, "tasks:workspace:" <> id)
  def subscribe({:decisions, id}), do: Phoenix.PubSub.subscribe(@pubsub, "tasks:decisions:" <> id)
  def subscribe({:events, id}), do: Phoenix.PubSub.subscribe(@pubsub, "tasks:events:" <> id)

  # Every change of a task that came from an issue of a linked repository
  # (`{:linked_task_updated, task_id}`), for its feedback on the git host.
  def subscribe(:linked), do: Phoenix.PubSub.subscribe(@pubsub, "tasks:linked")

  defp announce(%Task{} = task, kind) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "tasks:events:" <> task.workspace_id,
      {:task_event, %{id: task.id, title: task.title, kind: kind, reason: task.decision_reason}}
    )

    Notifications.notify_task(task, kind)
    task
  end

  defp notify(%Task{} = task) do
    Phoenix.PubSub.broadcast(@pubsub, "tasks:task:" <> task.id, {:task_updated, task})

    if task.linked_repo_id,
      do: Phoenix.PubSub.broadcast(@pubsub, "tasks:linked", {:linked_task_updated, task.id})

    Phoenix.PubSub.broadcast(
      @pubsub,
      "tasks:workspace:" <> task.workspace_id,
      {:task_updated, task}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "tasks:decisions:" <> task.workspace_id,
      {:pending_decisions, count_awaiting(%Workspace{id: task.workspace_id})}
    )

    Notifications.executions_changed(task.workspace_id)
  end

  # ── Reading ───────────────────────────────────────────────────────────────

  @doc """
  The workspace's most recent tasks, newest first, with their attempts
  (without the jobs). `filters` (blank values ignored): `"pipeline"` (its
  name), `"runner_id"`, `"project_id"`, `"user_id"` (who created it), `"q"`
  (text in the title or the prompt).
  """
  @spec list_tasks(Workspace.t(), map()) :: [Task.t()]
  def list_tasks(%Workspace{id: workspace_id}, filters \\ %{}) do
    query =
      from t in Task,
        where: t.workspace_id == ^workspace_id,
        order_by: [desc: t.inserted_at, desc: t.id],
        limit: @list_limit,
        preload: [:runner, :created_by_user, stage_runs: ^attempts_query()]

    filters
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.reduce(query, &filter/2)
    |> Repo.all()
  end

  defp filter({"pipeline", name}, query), do: where(query, [t], t.pipeline_name == ^name)

  defp filter({"q", text}, query) do
    pattern = "%" <> String.replace(text, ~r/([\\%_])/, "\\\\\\1") <> "%"
    where(query, [t], ilike(t.title, ^pattern) or ilike(t.prompt, ^pattern))
  end

  defp filter({key, id}, query) when key in ["runner_id", "project_id", "user_id"] do
    case {key, Ecto.UUID.cast(id)} do
      {_key, :error} -> where(query, false)
      {"runner_id", {:ok, id}} -> where(query, [t], t.runner_id == ^id)
      {"project_id", {:ok, id}} -> where(query, [t], t.project_id == ^id)
      {"user_id", {:ok, id}} -> where(query, [t], t.created_by_user_id == ^id)
    end
  end

  defp filter(_unknown, query), do: query

  @doc "The workspace's tasks with a pull request, newest first."
  @spec list_with_pull_request(Workspace.t()) :: [Task.t()]
  def list_with_pull_request(%Workspace{id: workspace_id}) do
    Repo.all(
      from t in Task,
        where: t.workspace_id == ^workspace_id and not is_nil(t.pr_url),
        order_by: [desc: t.updated_at, desc: t.id],
        limit: @list_limit,
        preload: [:runner, :created_by_user]
    )
  end

  @doc "How many of the workspace's tasks wait for a decision."
  @spec count_awaiting(Workspace.t()) :: non_neg_integer()
  def count_awaiting(%Workspace{id: workspace_id}) do
    Repo.aggregate(
      from(t in Task, where: t.workspace_id == ^workspace_id and t.status == :awaiting_decision),
      :count
    )
  end

  @doc """
  The workspace's tasks waiting for a decision, the longest waiting first,
  with their attempts (without the jobs).
  """
  @spec list_awaiting(Workspace.t()) :: [Task.t()]
  def list_awaiting(%Workspace{id: workspace_id}) do
    Repo.all(
      from t in Task,
        where: t.workspace_id == ^workspace_id and t.status == :awaiting_decision,
        order_by: [asc: t.updated_at, asc: t.id],
        preload: [:runner, :created_by_user, :decision_owner, stage_runs: ^attempts_query()]
    )
  end

  defp attempts_query,
    do: from(r in StageRun, order_by: [asc: r.index, asc: r.attempt, asc: r.requeue])

  @doc """
  The workspace in numbers: tasks running and waiting now, tasks that
  succeeded and that failed or were canceled (`failed`) since `since`, and
  what its jobs cost since then.
  """
  @spec stats(Workspace.t(), DateTime.t()) :: %{
          running: non_neg_integer(),
          awaiting: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          cost_usd: Decimal.t()
        }
  def stats(%Workspace{id: workspace_id}, since) do
    counts =
      Repo.all(
        from t in Task,
          where:
            t.workspace_id == ^workspace_id and
              (t.status in [:running, :awaiting_decision] or t.finished_at >= ^since),
          group_by: t.status,
          select: {t.status, count(t.id)}
      )
      |> Map.new()

    cost =
      Repo.one(
        from j in Job,
          where: j.workspace_id == ^workspace_id and j.finished_at >= ^since,
          select: sum(j.cost_usd)
      )

    %{
      running: Map.get(counts, :running, 0),
      awaiting: Map.get(counts, :awaiting_decision, 0),
      succeeded: Map.get(counts, :succeeded, 0),
      failed: Map.get(counts, :failed, 0) + Map.get(counts, :canceled, 0),
      cost_usd: cost || Decimal.new(0)
    }
  end

  @doc "One of the workspace's tasks, with its stage runs and their jobs."
  @spec get_task!(Workspace.t(), Ecto.UUID.t()) :: Task.t()
  def get_task!(%Workspace{id: workspace_id}, id) do
    Task
    |> Repo.get_by!(id: id, workspace_id: workspace_id)
    |> preload()
  end

  defp preload(task) do
    runs = from r in attempts_query(), preload: :job

    Repo.preload(task, [:runner, :created_by_user, :decision_owner, stage_runs: runs],
      force: true
    )
  end

  @doc "A changeset for the new-task form."
  @spec change_task(map()) :: Ecto.Changeset.t()
  def change_task(attrs \\ %{}), do: Task.create_changeset(%Task{}, attrs)

  # ── Starting ──────────────────────────────────────────────────────────────

  @doc """
  Creates a task and starts its first stage. The pipeline and the project
  (`project_id`) must belong to the workspace; the project decides the
  runner and the directory, and its runner must still offer the directory.
  With the runner offline, the first job waits for it
  (`waiting_for_runner?/2`).

  With `proposal: job`, the task is the one the task proposal `job` became
  (`PipeMaestro.Proposals.create_task/4`); a proposal already turned into a
  task gives an error on `proposal_job_id`. A task from an issue of a linked
  repository keeps the link: `issue: %{linked_repo_id, issue_number}`, or the
  one in the proposal's input.
  """
  @spec create_task(User.t(), Workspace.t(), map(), keyword()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(%User{} = user, %Workspace{} = workspace, attrs, opts \\ []) do
    proposal_job_id =
      case opts[:proposal] do
        %Job{id: id} -> id
        nil -> nil
      end

    {linked_repo_id, issue_number} = issue_link(opts)

    changeset =
      %Task{
        workspace_id: workspace.id,
        created_by_user_id: user.id,
        proposal_job_id: proposal_job_id,
        linked_repo_id: linked_repo_id,
        issue_number: issue_number
      }
      |> Task.create_changeset(attrs)
      |> put_pipeline(workspace)
      |> put_project(workspace)

    # The first stage's job is handed to the runner as it is created, so the
    # task is committed first: the runner may report back at once.
    with {:ok, task} <- Repo.insert(changeset) do
      task = task |> put_branch() |> start_or_queue() |> preload()
      Audit.record(workspace, user, "task.created", task, %{"pipeline" => task.pipeline_name})
      notify(task)
      {:ok, task}
    end
  end

  # The issue of a linked repository the task comes from: given, or the one
  # its proposal triaged.
  defp issue_link(opts) do
    case {opts[:issue], opts[:proposal]} do
      {%{linked_repo_id: repo_id, issue_number: number}, _} ->
        {repo_id, number}

      {nil, %Job{context: %{"proposal" => %{"input" => input}}}} ->
        {input["linked_repo_id"], input["issue_number"]}

      _none ->
        {nil, nil}
    end
  end

  defp put_pipeline(changeset, workspace) do
    case pipeline(workspace, Ecto.Changeset.get_field(changeset, :pipeline_id)) do
      %Pipeline{} = pipeline ->
        changeset
        |> Ecto.Changeset.put_change(:pipeline_name, pipeline.name)
        |> Ecto.Changeset.put_change(:pipeline_version, pipeline.version)
        |> Ecto.Changeset.put_change(:pipeline_context, Pipeline.context(pipeline))
        |> Ecto.Changeset.put_embed(:stages, pipeline.stages)

      :blank ->
        changeset

      nil ->
        Ecto.Changeset.add_error(changeset, :pipeline_id, "não é um pipeline deste workspace")
    end
  end

  defp pipeline(_workspace, nil), do: :blank

  defp pipeline(workspace, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(Pipeline, id: id, workspace_id: workspace.id)
      :error -> nil
    end
  end

  # The project decides where the task runs: its runner, its directory and
  # whether it is git; the task keeps a snapshot of the project as it is now.
  defp put_project(changeset, workspace) do
    case Ecto.Changeset.get_field(changeset, :project_id) do
      nil -> changeset
      id -> put_project(changeset, workspace, Projects.get_project(workspace, id))
    end
  end

  defp put_project(changeset, _workspace, nil),
    do: Ecto.Changeset.add_error(changeset, :project_id, "o projeto não existe mais")

  defp put_project(changeset, _workspace, %Project{runner: %Runner{revoked_at: nil}} = project) do
    case Runner.directory(project.runner, project.directory) do
      nil ->
        Ecto.Changeset.add_error(changeset, :directory, "o runner não oferece esse diretório")

      dir ->
        changeset
        |> Ecto.Changeset.put_change(:runner_id, project.runner_id)
        |> Ecto.Changeset.put_change(:directory, project.directory)
        |> Ecto.Changeset.put_change(:git, dir["git"] == true)
        |> Ecto.Changeset.put_change(:project, Project.snapshot(project))
    end
  end

  defp put_project(changeset, _workspace, %Project{}),
    do: Ecto.Changeset.add_error(changeset, :project_id, "o projeto precisa de um runner")

  # Past the workspace's limit of tasks at once, the task waits in line.
  defp start_or_queue(task) do
    if room?(task.workspace_id, task.id),
      do: start_stage(task, 0, nil),
      else: task |> Ecto.Changeset.change(status: :queued) |> Repo.update!()
  end

  defp room?(workspace_id, except_task_id) do
    case Repo.one(from w in Workspace, where: w.id == ^workspace_id, select: w.max_running_tasks) do
      nil ->
        true

      limit ->
        running =
          Repo.aggregate(
            from(t in Task,
              where:
                t.workspace_id == ^workspace_id and t.status == :running and
                  t.id != ^except_task_id
            ),
            :count
          )

        running < limit
    end
  end

  # A task stopped running: the oldest one in line, if any, takes its place.
  defp start_next_queued(workspace_id) do
    next =
      Repo.one(
        from t in Task,
          where: t.workspace_id == ^workspace_id and t.status == :queued,
          order_by: [asc: t.inserted_at, asc: t.id],
          limit: 1
      )

    if next && room?(workspace_id, next.id) do
      next |> start_stage(0, nil) |> preload() |> notify()
    end

    :ok
  end

  defp put_branch(%Task{git: false} = task), do: task

  defp put_branch(%Task{} = task) do
    slug =
      task.title
      |> String.normalize(:nfd)
      |> String.replace(~r/[^\x00-\x7F]/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    branch = "cp/#{slug}-#{String.slice(task.id, 0, 8)}"
    task |> Ecto.Changeset.change(branch: branch) |> Repo.update!()
  end

  # Starts attempt `attempt` (or 1) of the stage at `index`: a stage run and
  # its job, with the prompt and context the runner needs, and the answers a
  # person gave to the questions of the pause it comes from, if any.
  defp start_stage(%Task{} = task, index, instructions, attempt \\ 1, answers \\ nil) do
    stage = Enum.at(task.stages, index)
    instructions = join_instructions([instructions, task.pending_instructions])

    task
    |> run_stage(%StageRun{
      task_id: task.id,
      index: index,
      key: stage.key,
      name: stage.name,
      attempt: attempt,
      instructions: blank_to_nil(instructions),
      feedback: if(attempt > 1, do: previous_feedback(task, index)),
      answers: answers
    })
    # Written even when the struct already says nil (a step clears it first).
    |> Ecto.Changeset.force_change(:pending_instructions, nil)
    |> Repo.update!()
  end

  # Runs a lost run's stage again: the same attempt, instructions, answers
  # and feedback, one more requeue. Instructions a person left for later stay
  # for later.
  defp requeue_stage(%Task{} = task, %StageRun{} = lost) do
    task
    |> run_stage(%StageRun{
      task_id: task.id,
      index: lost.index,
      key: lost.key,
      name: lost.name,
      attempt: lost.attempt,
      requeue: lost.requeue + 1,
      instructions: lost.instructions,
      feedback: lost.feedback,
      answers: lost.answers
    })
    |> Repo.update!()
  end

  # Inserts `stage_run` and its job, with the prompt and context the runner
  # needs; returns the change that marks the task running at its stage.
  defp run_stage(%Task{} = task, %StageRun{index: index} = new_run) do
    stage = Enum.at(task.stages, index)
    stage_run = Repo.insert!(new_run)

    prompt =
      Prompt.build(stage, %{
        task_id: task.id,
        title: task.title,
        description: task.prompt,
        directory: task.directory,
        project: task.project,
        stage_index: index,
        previous: Enum.take(task.stages, step_first(task, index)),
        instructions: stage_run.instructions,
        feedback: stage_run.feedback,
        answers: stage_run.answers,
        contract: if(place = contract_place(task, index), do: Contract.prompt(place)),
        files: uploads_files?(task)
      })

    Jobs.create_stage_job(%{
      workspace_id: task.workspace_id,
      runner_id: task.runner_id,
      project_id: task.project_id,
      created_by_user_id: task.created_by_user_id,
      stage_run_id: stage_run.id,
      prompt: prompt,
      context: job_context(task, stage, index)
    })

    task
    |> Ecto.Changeset.change(
      status: :running,
      current_stage: index,
      decision_reason: nil,
      decision_questionnaire: nil,
      decision_analysis_job_id: nil,
      decision_owner_id: nil,
      decision_due_at: nil,
      pending_issue_comment: nil,
      finished_at: nil
    )
  end

  # Whether the task's runner, as of its latest hello, sends a job's files.
  defp uploads_files?(%Task{runner: %Runner{} = runner}),
    do: Runners.capable?(runner, JobFiles.capability())

  defp uploads_files?(%Task{runner_id: nil}), do: false

  defp uploads_files?(%Task{runner_id: runner_id}) do
    case Repo.get(Runner, runner_id) do
      %Runner{} = runner -> Runners.capable?(runner, JobFiles.capability())
      nil -> false
    end
  end

  defp join_instructions(texts) do
    case texts |> Enum.map(&blank_to_nil/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      texts -> Enum.join(texts, "\n\n")
    end
  end

  # A new attempt after a failed one learns what went wrong.
  defp previous_feedback(task, index) do
    previous =
      Repo.one(
        from r in StageRun,
          where: r.task_id == ^task.id and r.index == ^index and r.status != :lost,
          order_by: [desc: r.attempt, desc: r.requeue],
          limit: 1,
          preload: :job
      )

    case previous do
      %StageRun{status: :failed} = run ->
        Engine.feedback(run.error, run.summary, run.job && run.job.gates)

      _passed_or_none ->
        nil
    end
  end

  defp job_context(task, stage, index) do
    %{
      "directory" => task.directory,
      "worktree" => if(task.git, do: %{"task_id" => task.id, "branch" => task.branch}),
      "output_schema" => Prompt.output_schema(stage),
      "model" => stage.model,
      "max_budget_usd" => stage.max_budget_usd && Decimal.to_float(stage.max_budget_usd),
      "artifact_path" => Prompt.artifact_path(task.id, index, stage.key),
      "timeout_ms" => stage.timeout_minutes * 60_000,
      "setup" => Project.setup(task.project),
      "gates" => gates(stage, task),
      "system_prompt" => context(task, "system_prompt"),
      "mcp_config" => context(task, "mcp_config"),
      "agents" => context(task, "agents"),
      "agent" => stage.agent,
      "parallel" => if(grouped?(task, index), do: true),
      "delivery" => if(not grouped?(task, index), do: delivery(task, index)),
      "checks" => if(place = contract_place(task, index), do: Contract.checks(stage, place)),
      "sync" => if(task.git, do: true),
      "artifacts" => earlier_artifacts(task, index)
    }
    |> Map.merge(session_context(task, stage, index))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The agent's session: kept when the next stage continues it, resumed when
  # this stage continues the one before.
  defp session_context(task, stage, index) do
    if resumable?(task) do
      %{
        "persist_session" => if(continued?(task, index + 1), do: true),
        "resume_session_id" =>
          if(stage.context == "continue", do: previous_session_id(task, index))
      }
    else
      %{}
    end
  end

  # Whether the task's runner keeps and resumes the agent's sessions (ADR
  # 0041): one that does not runs every stage from scratch.
  defp resumable?(%Task{runner_id: nil}), do: false

  defp resumable?(%Task{runner_id: runner_id}) do
    case Repo.get(Runner, runner_id) do
      %Runner{} = runner -> Runners.capable?(runner, "resume_session")
      nil -> false
    end
  end

  defp continued?(task, index),
    do: match?(%Stage{context: "continue"}, Enum.at(task.stages, index))

  # The session of the stage before, as its last passed attempt reported it:
  # a new attempt of this stage resumes the same one.
  defp previous_session_id(task, index) do
    Repo.one(
      from r in StageRun,
        join: j in assoc(r, :job),
        where: r.task_id == ^task.id and r.index == ^(index - 1) and r.status == :passed,
        order_by: [desc: r.attempt],
        limit: 1,
        select: j.session_id
    )
  end

  # Where a stage held to the platform's contract (`Contract`) is in its task:
  # a stage that delivers, not one of a group.
  defp contract_place(
         %Task{git: true, pipeline_context: %{"delivery" => mode}} = task,
         index
       )
       when mode in ["commit", "pr"] do
    if not grouped?(task, index) do
      %{
        task_id: task.id,
        branch: task.branch,
        index: index,
        last?: index == length(task.stages) - 1,
        pr?: mode == "pr"
      }
    end
  end

  defp contract_place(_task, _index), do: nil

  # The earlier stages' artifacts, as the control plane kept them: the runner
  # writes back the ones missing on disk (a worktree made again, another
  # runner, or the folder the last stage took out of the branch).
  defp earlier_artifacts(%Task{git: true} = task, index) do
    first = step_first(task, index)

    artifacts =
      Repo.all(
        from r in StageRun,
          where:
            r.task_id == ^task.id and r.index < ^first and r.status == :passed and
              not is_nil(r.artifact),
          order_by: [asc: r.index, desc: r.attempt, desc: r.requeue],
          distinct: r.index,
          select: {r.index, r.key, r.artifact}
      )

    case artifacts do
      [] ->
        nil

      artifacts ->
        for {i, key, content} <- artifacts,
            do: %{"path" => Prompt.artifact_path(task.id, i, key), "content" => content}
    end
  end

  defp earlier_artifacts(_task, _index), do: nil

  # What the runner delivers once the stage passed its checks and gates: the
  # push and the platform's block of the pull request (the agent committed).
  # With a linked repository whose connection lets the platform call the
  # host, the runner only pushes: the platform keeps the pull request
  # (`PipeMaestro.Integrations.Feedback`).
  defp delivery(%Task{git: true, pipeline_context: %{"delivery" => "pr"}} = task, index)
       when is_binary(task.linked_repo_id) do
    if Integrations.keeps_pull_request?(task),
      do: %{"push" => true},
      else: task |> runner_delivery(index) |> Map.put("status", stage_status(task, index))
  end

  defp delivery(task, index), do: runner_delivery(task, index)

  # The commit status the runner sets for a stage that passed, when the
  # connection leaves the host to it.
  defp stage_status(task, index) do
    stage = Enum.at(task.stages, index)
    workspace = Repo.get!(Workspace, task.workspace_id)

    %{
      "context" => "pipemaestro/#{stage.key}",
      "state" => "success",
      "description" => stage.name,
      "target_url" => "#{Integrations.public_url()}/w/#{workspace.slug}/tasks/#{task.id}"
    }
  end

  defp runner_delivery(%Task{git: true, pipeline_context: %{"delivery" => mode}} = task, index)
       when mode in ["commit", "pr"] do
    base =
      if mode == "pr",
        do: %{
          "push" => true,
          "pr" => %{
            "title" => task.title,
            "block" => pr_body(task, index),
            "ready" => index == length(task.stages) - 1
          }
        },
        else: %{}

    base =
      if task.issue_url && task.pending_issue_comment,
        do:
          Map.put(base, "issue_comment", %{
            "url" => task.issue_url,
            "body" => task.pending_issue_comment
          }),
        else: base

    if base == %{}, do: nil, else: base
  end

  defp runner_delivery(_task, _index), do: nil

  @doc """
  The platform's block of the task's pull request (`PipeMaestroProtocol.PrText`):
  the request, `Closes <issue>` and the stages done so far.
  """
  @spec pr_block(Task.t()) :: String.t()
  def pr_block(%Task{status: :succeeded} = task), do: pr_body(task, length(task.stages) - 1)
  def pr_block(%Task{} = task), do: pr_body(task, task.current_stage)

  # The stages before this one are done; the last one's delivery marks the PR
  # ready, so then every stage is.
  defp pr_body(task, index) do
    last? = index == length(task.stages) - 1

    stages =
      task.stages
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {stage, i} ->
        "- [#{if i < index or last?, do: "x", else: " "}] #{stage.name}"
      end)

    closes = if task.issue_url, do: "Closes #{task.issue_url}\n\n", else: ""

    """
    #{task.prompt}

    #{closes}## Etapas (#{task.pipeline_name})

    #{stages}

    _Bloco mantido pelo PipeMaestro; o resto da descrição é livre. Os artefatos de cada etapa ficam em `#{Contract.artifacts_dir(task.id)}/` enquanto a tarefa roda e saem da branch na última etapa; a plataforma guarda todos._
    """
  end

  defp context(%Task{pipeline_context: nil}, _key), do: nil
  defp context(%Task{pipeline_context: context}, key), do: context[key]

  # A gate whose command is only a project setting the task does not have
  # renders to nothing and is dropped.
  defp gates(stage, task) do
    gates =
      for gate <- stage.gates,
          command = String.trim(Prompt.render_command(gate["command"], %{project: task.project})),
          command != "",
          do: %{gate | "command" => command}

    if gates == [], do: nil, else: gates
  end

  # ── The gate ──────────────────────────────────────────────────────────────

  @doc """
  Moves a task along once the job of its current stage ends: records what the
  stage produced and applies the gate (`PipeMaestro.Tasks.Engine`).
  """
  @spec job_finished(Job.t()) :: :ok
  def job_finished(%Job{stage_run_id: stage_run_id} = job) when is_binary(stage_run_id) do
    stage_run = Repo.get!(StageRun, stage_run_id)
    task = Repo.get!(Task, stage_run.task_id)

    if Task.active?(task) and stage_run.status == :running do
      stage = Enum.at(task.stages, stage_run.index)
      outcome = Engine.gate(job, stage, stage_run.attempt)

      stage_run = record_stage_run(stage_run, job, outcome)

      task = task |> maybe_record_worktree(job) |> maybe_record_pr(job)

      if grouped?(task, stage_run.index),
        do: task |> after_group_stage(stage_run, outcome) |> preload() |> notify(),
        else: task |> advance_after(stage_run, outcome) |> preload() |> notify()
    end

    :ok
  end

  @doc """
  A stage's job was lost by its runner: it restarted, updated or crashed
  while running it (`PipeMaestro.Jobs.reconcile/2`), or stopped it on its own.
  Not an attempt and no gate: the run becomes `lost` and the stage runs again
  in the same attempt, on the same runner and worktree, up to
  `max_lost_requeues` times; past that the task waits for a person, with no
  analysis (the agent did nothing wrong). Each loss is an event of the runner
  (`job_lost`). A loss already told is ignored.
  """
  @spec job_lost(Job.t()) :: :ok
  def job_lost(%Job{stage_run_id: stage_run_id} = job) when is_binary(stage_run_id) do
    stage_run = Repo.get!(StageRun, stage_run_id)
    task = Repo.get!(Task, stage_run.task_id)

    if Task.active?(task) and stage_run.status == :running do
      stage_run =
        stage_run
        |> Ecto.Changeset.change(
          status: :lost,
          error: "Perdida: o runner reiniciou ou caiu durante a execução."
        )
        |> Repo.update!()

      record_loss(job, task, stage_run)

      task
      |> after_loss(stage_run)
      |> preload()
      |> notify()
    end

    :ok
  end

  defp record_loss(%Job{runner_id: runner_id} = job, task, stage_run) do
    case Repo.get(Runner, runner_id) do
      nil ->
        :ok

      runner ->
        RunnerTelemetry.record_event(
          runner,
          "job_lost",
          "warning",
          "O job da etapa \"#{stage_run.name}\" foi perdido: o runner reiniciou ou caiu.",
          job_id: job.id,
          task_id: task.id
        )

        :ok
    end
  end

  defp after_loss(task, stage_run) do
    max = Application.get_env(:pipe_maestro, :max_lost_requeues, @max_lost_requeues)
    first = step_first(task, stage_run.index)

    cond do
      stage_run.requeue < max ->
        task |> requeue_stage(stage_run) |> keep_current(first)

      not grouped?(task, stage_run.index) ->
        await(task, lost_reason(stage_run))

      Enum.any?(latest_runs(task, first), &(&1.status == :running)) ->
        task

      true ->
        close_step(task, first)
    end
  end

  defp lost_reason(stage_run) do
    "A etapa \"#{stage_run.name}\" foi interrompida #{stage_run.requeue + 1} vezes " <>
      "por queda ou reinício do runner."
  end

  defp record_stage_run(stage_run, job, outcome) do
    output = job.structured_output

    {status, error} = run_status(outcome)

    stage_run
    |> Ecto.Changeset.change(
      status: status,
      summary: if(is_map(output), do: output["resumo"]),
      structured_output: output,
      artifact: job.artifact && String.slice(job.artifact, 0, @max_artifact_bytes),
      error: error
    )
    |> Repo.update!()
  end

  defp run_status(:passed), do: {:passed, nil}
  defp run_status({:paused, _reason}), do: {:passed, nil}
  defp run_status(:canceled), do: {:canceled, nil}
  defp run_status({:blocked, _reason}), do: {:blocked, nil}
  defp run_status({_retry_or_exhausted, error}), do: {:failed, error}

  # The pull request the runner keeps, and the last commit it pushed (where a
  # linked repository's commit statuses go).
  defp maybe_record_pr(task, %Job{delivery: %{} = delivery}) do
    changes =
      [
        is_binary(delivery["pr_url"]) && {:pr_url, delivery["pr_url"]},
        (delivery["pushed"] == true and is_binary(delivery["commit"])) &&
          {:head_sha, delivery["commit"]}
      ]
      |> Enum.filter(& &1)

    if changes == [], do: task, else: task |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  defp maybe_record_pr(task, _job), do: task

  defp maybe_record_worktree(%Task{worktree: nil} = task, %Job{workdir: workdir})
       when is_binary(workdir),
       do: task |> Ecto.Changeset.change(worktree: workdir) |> Repo.update!()

  defp maybe_record_worktree(task, _job), do: task

  # A task past its budget stops for a person instead of going on by itself
  # (to the next stage, or to another attempt); when it would stop anyway, the
  # reason it stops for says more.
  defp advance_after(task, stage_run, outcome) do
    goes_on = outcome == :passed or match?({:retry, _error}, outcome)

    case goes_on && over_budget(task) do
      {:over, cap, spent} ->
        await(
          task,
          "A tarefa atingiu o orçamento de US$ #{cap}: já gastou US$ #{Decimal.round(spent, 4)}."
        )

      _within_budget ->
        go_on(task, stage_run, outcome)
    end
  end

  defp over_budget(%Task{pipeline_context: %{"max_cost_usd" => cap}} = task)
       when is_binary(cap) do
    spent = cost(task)
    if Decimal.compare(spent, Decimal.new(cap)) == :gt, do: {:over, cap, spent}, else: :ok
  end

  defp over_budget(_task), do: :ok

  defp go_on(task, stage_run, outcome) do
    stage = Enum.at(task.stages, stage_run.index)

    case outcome do
      :passed when task.pause_requested ->
        await(task, "Alguém pediu uma pausa depois da etapa \"#{stage.name}\".")

      :passed ->
        next_or_finish(task, stage_run.index + 1, nil)

      {:paused, reason} ->
        await(task, "A etapa \"#{stage.name}\" terminou, mas #{reason}.")

      # Interrupted (`interrupt/2`): the task waits for a person, not ends.
      :canceled when task.pause_requested ->
        await(task, "A etapa \"#{stage.name}\" foi interrompida.")

      :canceled ->
        finish(task, :canceled)

      {:blocked, reason} ->
        await(
          task,
          "A etapa \"#{stage.name}\" está bloqueada: #{reason}",
          asking(Questionnaire.for_run(stage_run.structured_output))
        )

      {:retry, _error} ->
        start_stage(task, stage_run.index, stage_run.instructions, stage_run.attempt + 1)

      {:exhausted, error} ->
        await(
          task,
          "A etapa \"#{stage.name}\" falhou em #{stage_run.attempt} tentativa(s): #{error}",
          :analysis
        )
    end
  end

  # A block with questions asks them; one with nothing to ask is analysed
  # like a failure.
  defp asking(nil), do: :analysis
  defp asking(questionnaire), do: {:questionnaire, questionnaire}

  # A stage run again (after a redo) keeps counting its attempts.
  defp next_or_finish(task, index, instructions, answers \\ nil) do
    if index < length(task.stages),
      do: start_step(task, index, instructions, nil, answers),
      else: finish(task, :succeeded)
  end

  # ── Steps: a stage alone, or a group of stages that run at once ──────────

  defp group_of(task, index) do
    case Enum.at(task.stages, index) do
      %{group: group} when group not in [nil, ""] -> group
      _alone -> nil
    end
  end

  defp grouped?(task, index), do: group_of(task, index) != nil

  @doc """
  The indexes of the stages of the step `index` belongs to, in order: just
  `index`, or every stage of its group.
  """
  @spec step_indexes(Task.t(), non_neg_integer()) :: [non_neg_integer()]
  def step_indexes(%Task{} = task, index), do: step(task, index)

  # The indexes of the step `index` belongs to, in order.
  defp step(task, index),
    do: task.stages |> Pipelines.steps() |> Enum.find([index], &(index in &1))

  defp step_first(task, index), do: task |> step(index) |> hd()
  defp step_last(task, index), do: task |> step(index) |> List.last()

  # Starts the stages of the step at `index` (or `only` some of them), every
  # one with the instructions and answers; the task's current stage is the
  # step's first.
  defp start_step(task, index, instructions, only \\ nil, answers \\ nil) do
    instructions = join_instructions([instructions, task.pending_instructions])
    task = %{task | pending_instructions: nil}

    task =
      Enum.reduce(only || step(task, index), task, fn i, task ->
        start_stage(task, i, instructions, last_attempt(task, i) + 1, answers)
      end)

    keep_current(task, step_first(task, index))
  end

  defp keep_current(%Task{current_stage: index} = task, index), do: task

  defp keep_current(task, index),
    do: task |> Ecto.Changeset.change(current_stage: index) |> Repo.update!()

  # A stage of a group ended: it retries on its own; once none of the group
  # runs, the step closes.
  defp after_group_stage(task, stage_run, outcome) do
    first = step_first(task, stage_run.index)

    case outcome do
      :canceled when not task.pause_requested ->
        finish(task, :canceled)

      {:retry, _error} ->
        task
        |> start_stage(stage_run.index, stage_run.instructions, stage_run.attempt + 1)
        |> keep_current(first)

      _passed_blocked_or_exhausted ->
        if Enum.any?(latest_runs(task, first), &(&1.status == :running)),
          do: task,
          else: close_step(task, first)
    end
  end

  defp latest_runs(task, first), do: Enum.map(step(task, first), &latest_run(task, &1))

  # Every stage of the group ended: on to the next step, or a pause that says
  # what each stage needs.
  defp close_step(task, first) do
    runs = latest_runs(task, first)

    problems = for run <- runs, run.status in [:blocked, :failed, :lost], do: problem(run)

    pauses =
      for run <- runs,
          stage = Enum.at(task.stages, run.index),
          run.status == :passed,
          reason = pause_reason(stage, run),
          do: "A etapa \"#{stage.name}\" terminou, mas #{reason}."

    cond do
      problems != [] -> await(task, Enum.join(problems, " "), step_asking(runs))
      pauses != [] -> await(task, Enum.join(pauses, " "))
      Enum.any?(runs, &(&1.status == :canceled)) -> await(task, "O passo foi interrompido.")
      task.pause_requested -> await(task, "Alguém pediu uma pausa depois deste passo.")
      true -> next_or_finish(task, step_last(task, first) + 1, nil)
    end
  end

  defp problem(%StageRun{status: :blocked} = run),
    do: "A etapa \"#{run.name}\" está bloqueada: #{run.summary}"

  defp problem(%StageRun{status: :failed} = run),
    do: "A etapa \"#{run.name}\" falhou: #{run.error}"

  defp problem(%StageRun{status: :lost} = run), do: lost_reason(run)

  # A stage lost past the limit is no fault of the agent's: nothing to analyse.
  defp step_asking(runs) do
    if Enum.any?(runs, &(&1.status in [:blocked, :failed])),
      do: group_asking(runs),
      else: :none
  end

  # The questions of the group's blocked stages, put together, each marked
  # with its stage (`"etapa"`) for the screen; none, and a stage that failed
  # or blocked with nothing to ask is analysed.
  defp group_asking(runs) do
    questionnaires =
      for run <- runs,
          run.status == :blocked,
          questionnaire = Questionnaire.for_run(run.structured_output),
          do: {run, questionnaire}

    questions =
      for {run, questionnaire} <- questionnaires,
          question <- questionnaire["perguntas"],
          do: Map.put(question, "etapa", run.name)

    origin =
      if Enum.any?(questionnaires, fn {_run, q} -> q["origem"] == "agente" end),
        do: "agente",
        else: "opcoes"

    if questions == [],
      do: :analysis,
      else: {:questionnaire, %{"origem" => origin, "perguntas" => questions}}
  end

  defp pause_reason(stage, run), do: Engine.rule_pause(run.structured_output, stage.rules)

  # `asking` says what the person is asked besides the reason: the
  # questionnaire of a block, an analysis the agent is asked for (a failure),
  # or nothing (a rule, the budget, a pause someone asked for).
  defp await(task, reason, asking \\ :none) do
    questionnaire =
      case asking do
        {:questionnaire, questionnaire} -> questionnaire
        _no_questions -> nil
      end

    task =
      task
      |> Ecto.Changeset.change(
        status: :awaiting_decision,
        decision_reason: reason,
        decision_questionnaire: questionnaire,
        decision_analysis_job_id: nil,
        pause_requested: false,
        decision_owner_id: task.created_by_user_id,
        decision_due_at: DateTime.add(now(), @decision_hours, :hour)
      )
      |> Repo.update!()
      |> announce(:awaiting)
      |> tap(&start_next_queued(&1.workspace_id))

    if asking == :analysis, do: request_analysis(task), else: task
  end

  defp finish(task, status) do
    task
    |> Ecto.Changeset.change(
      status: status,
      decision_reason: nil,
      decision_questionnaire: nil,
      decision_analysis_job_id: nil,
      finished_at: now()
    )
    |> Ecto.Changeset.change(merge_fields(task, status))
    |> Repo.update!()
    |> announce(status)
    |> tap(&tell_merge_blocked/1)
    |> tap(&start_next_queued(&1.workspace_id))
  end

  defp tell_merge_blocked(%Task{status: :succeeded, merge_state: "blocked"} = task),
    do: Notifications.notify_task(task, :merge_blocked)

  defp tell_merge_blocked(_task), do: []

  # With `auto_merge`, a task that succeeded waits for the host's checks to
  # merge its pull request (`PipeMaestro.Integrations.AutoMerge`), which only
  # the platform can do: without a connection that lets it call the host,
  # the merge is blocked from the start. A task canceled while it was being
  # fixed for the merge no longer waits for it.
  defp merge_fields(%Task{pipeline_context: %{"auto_merge" => true}} = task, :succeeded) do
    if Integrations.keeps_pull_request?(task),
      do: [merge_state: "waiting_checks", merge_reason: nil, merge_waiting_since: now()],
      else: [
        merge_state: "blocked",
        merge_reason:
          "o repositório não está vinculado por uma integração que deixe a plataforma fazer o merge",
        merge_waiting_since: nil
      ]
  end

  defp merge_fields(%Task{merge_state: state}, :canceled)
       when state in ["waiting_checks", "fixing"],
       do: [merge_state: nil, merge_waiting_since: nil]

  defp merge_fields(_task, _status), do: []

  # ── The analysis of a failure ─────────────────────────────────────────────

  @doc """
  Asks the agent, on behalf of the task's creator, to analyse why the task
  paused (`PipeMaestro.Proposals.AnalysisKind`): its diagnosis and questions
  become the task's questionnaire once it ends (`analysis_finished/1`). With
  no creator, or when the request is refused, there is no analysis: the
  person decides by hand. Returns the task, with its analysis job when asked.
  """
  @spec request_analysis(Task.t()) :: Task.t()
  def request_analysis(%Task{} = task) do
    with %User{} = user <- task.created_by_user_id && Repo.get(User, task.created_by_user_id),
         workspace = Repo.get!(Workspace, task.workspace_id),
         {:ok, job} <- Proposals.request("analysis", user, workspace, %{"task_id" => task.id}) do
      task |> Ecto.Changeset.change(decision_analysis_job_id: job.id) |> Repo.update!()
    else
      nil ->
        task

      {:error, changeset} ->
        Logger.warning(
          "Análise automática da tarefa #{task.id} recusada: #{inspect(changeset.errors)}"
        )

        task
    end
  end

  @doc """
  The analysis of a paused task's failure ended. When it is still the one
  the task waits on (same pause, no decision since) and it answered with
  valid questions, they become the task's questionnaire, with the
  diagnosis. Anything else leaves the task as it is, and the screens show
  the analysis did not get ready.
  """
  @spec analysis_finished(Job.t()) :: :ok
  def analysis_finished(%Job{} = job) do
    input = Proposals.input(job)

    with id when is_binary(id) <- input["task_id"],
         %Task{decision_analysis_job_id: job_id} = task when job_id == job.id <-
           Repo.get(Task, id),
         true <- AnalysisKind.current?(input, task) do
      task =
        case Proposals.result(job) do
          {:ok, result} ->
            questionnaire = %{
              "origem" => "analise",
              "diagnostico" => result.diagnosis,
              "perguntas" => result.questions
            }

            task
            |> Ecto.Changeset.change(decision_questionnaire: questionnaire)
            |> Repo.update!()

          {:error, reason} ->
            Logger.info("A análise da tarefa #{task.id} não ficou pronta: #{reason}")
            task
        end

      task |> preload() |> notify()
    end

    :ok
  end

  @typedoc """
  The questionnaire of a task's pause (`nil` when there is none) and how its
  analysis goes: `:running`, `:failed` (it ended with no questionnaire) or
  `:none` (no analysis, or one that gave the questionnaire).
  """
  @type questionnaire_state :: %{
          questionnaire: Questionnaire.t() | nil,
          analysis: :none | :running | :failed
        }

  @doc "What a task waiting for a decision asks the person, for the screens."
  @spec questionnaire(Task.t()) :: questionnaire_state()
  def questionnaire(%Task{status: :awaiting_decision} = task) do
    analysis =
      case task.decision_analysis_job_id && Repo.get(Job, task.decision_analysis_job_id) do
        %Job{} = job when task.decision_questionnaire == nil ->
          if Job.active?(job), do: :running, else: :failed

        _none_or_done ->
          :none
      end

    %{questionnaire: task.decision_questionnaire, analysis: analysis}
  end

  def questionnaire(%Task{}), do: %{questionnaire: nil, analysis: :none}

  # An analysis is good only for its pause: deciding stops it.
  defp cancel_analysis(nil), do: :ok

  defp cancel_analysis(job_id) do
    case Repo.get(Job, job_id) do
      %Job{} = job -> if Job.active?(job), do: Jobs.request_cancel(job)
      nil -> nil
    end

    :ok
  end

  # ── Decisions ─────────────────────────────────────────────────────────────

  @typedoc """
  Who decided and what they chose: `:by` (the user), `:choice` (one of the
  options the agent proposed, `options/1`) and `:answers` (to the pause's
  questionnaire, `Questionnaire.answer()`), all optional.
  """
  @type decision_opts :: [
          by: User.t() | nil,
          via: String.t() | nil,
          choice: String.t() | nil,
          answers: [Questionnaire.answer()] | nil
        ]

  @doc """
  What needs attention among the workspace's tasks that have not ended:
  `{:runner_offline, task}` when its runner is not in `online_runner_ids`
  (the task cannot move, `runner_offline?/2`), `{:decision_overdue, task}` when its decision is
  past its deadline, and `{:near_budget, task, spent, cap}` when it has
  spent 80% or more of its pipeline's cap per task, and
  `{:runner_near_limit, task, runner}` when it runs on a runner whose account
  is near its usage limits (`PipeMaestro.Runners.near_limit?/2`).
  """
  @spec alerts(Workspace.t(), MapSet.t()) :: [tuple()]
  def alerts(%Workspace{id: workspace_id}, online_runner_ids) do
    active =
      Repo.all(
        from t in Task,
          where: t.workspace_id == ^workspace_id and t.status in [:running, :awaiting_decision],
          order_by: [asc: t.inserted_at],
          preload: [:runner]
      )

    Enum.flat_map(active, fn task ->
      offline =
        if runner_offline?(task, online_runner_ids), do: [{:runner_offline, task}], else: []

      offline ++ overdue(task) ++ near_budget(task) ++ near_limit(task)
    end)
  end

  @doc """
  Whether `task` is running on a runner that is not in `online_runner_ids`:
  it cannot move until the runner comes back. A task in any other status is
  never held up by its runner.
  """
  @spec runner_offline?(Task.t(), MapSet.t()) :: boolean()
  def runner_offline?(%Task{status: :running, runner_id: runner_id}, online_runner_ids),
    do: not MapSet.member?(online_runner_ids, runner_id)

  def runner_offline?(%Task{}, _online_runner_ids), do: false

  @doc """
  Whether `task` has a job waiting for its runner, which is not in
  `online_runner_ids`: the job is handed over when the runner connects.
  """
  @spec waiting_for_runner?(Task.t(), MapSet.t()) :: boolean()
  def waiting_for_runner?(%Task{runner_id: nil}, _online_runner_ids), do: false

  def waiting_for_runner?(%Task{runner_id: runner_id} = task, online_runner_ids) do
    not MapSet.member?(online_runner_ids, runner_id) and queued_job?(task)
  end

  defp queued_job?(%Task{stage_runs: runs}) when is_list(runs),
    do: Enum.any?(runs, &match?(%StageRun{job: %Job{status: :queued}}, &1))

  defp queued_job?(%Task{id: task_id}) do
    Repo.exists?(
      from j in Job,
        join: r in StageRun,
        on: r.id == j.stage_run_id,
        where: r.task_id == ^task_id and j.status == :queued
    )
  end

  @doc """
  The next instant at which one of `alerts` (`alerts/2`) ends by itself, with
  no event: the earliest future reset among the runners near their limit.
  `nil` when none of them ends with time.
  """
  @spec alerts_change_at([tuple()], DateTime.t()) :: DateTime.t() | nil
  def alerts_change_at(alerts, now \\ DateTime.utc_now()) do
    alerts
    |> Enum.flat_map(fn
      {:runner_near_limit, _task, %Runner{rate_limit: %{} = limit}} ->
        [Runners.resets_at(limit["resets_at"])]

      _other ->
        []
    end)
    |> Enum.filter(&(match?(%DateTime{}, &1) and DateTime.compare(&1, now) == :gt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp near_limit(%Task{status: :running, runner: %Runner{} = runner} = task) do
    if Runners.near_limit?(runner), do: [{:runner_near_limit, task, runner}], else: []
  end

  defp near_limit(_task), do: []

  defp overdue(%Task{status: :awaiting_decision, decision_due_at: %DateTime{} = due} = task) do
    if DateTime.compare(due, DateTime.utc_now()) == :lt, do: [{:decision_overdue, task}], else: []
  end

  defp overdue(_task), do: []

  defp near_budget(%Task{pipeline_context: %{"max_cost_usd" => cap}} = task)
       when is_binary(cap) do
    spent = cost(task)
    threshold = Decimal.mult(Decimal.new(cap), Decimal.new("0.8"))
    if Decimal.compare(spent, threshold) != :lt, do: [{:near_budget, task, spent, cap}], else: []
  end

  defp near_budget(_task), do: []

  @doc "Passes a paused task's decision on to `user`, a member of its workspace."
  @spec assign_decision(Task.t(), User.t()) :: {:ok, Task.t()} | {:error, :not_a_member}
  def assign_decision(%Task{} = task, %User{} = user) do
    task = Repo.get!(Task, task.id)

    if Workspaces.member?(%Workspace{id: task.workspace_id}, user),
      do: update_and_notify(task, decision_owner_id: user.id),
      else: {:error, :not_a_member}
  end

  @doc "What a task's jobs have cost so far."
  @spec cost(Task.t()) :: Decimal.t()
  def cost(%Task{id: task_id}) do
    Repo.one(
      from j in Job,
        join: r in StageRun,
        on: r.id == j.stage_run_id,
        where: r.task_id == ^task_id,
        select: sum(j.cost_usd)
    ) || Decimal.new(0)
  end

  @doc "What each of the tasks' jobs have cost so far, by task id (a task without jobs is left out)."
  @spec costs([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => Decimal.t()}
  def costs(task_ids) when is_list(task_ids) do
    Repo.all(
      from j in Job,
        join: r in StageRun,
        on: r.id == j.stage_run_id,
        where: r.task_id in ^task_ids,
        group_by: r.task_id,
        select: {r.task_id, coalesce(sum(j.cost_usd), 0)}
    )
    |> Map.new()
  end

  @doc "The options the agent proposed for the decision a task waits for."
  @spec options(Task.t()) :: [String.t()]
  def options(%Task{} = task) do
    task = Repo.get!(Task, task.id)

    with :awaiting_decision <- task.status,
         %StageRun{structured_output: %{"opcoes" => options}} when is_list(options) <-
           latest_run(task, task.current_stage) do
      Enum.filter(options, &is_binary/1)
    else
      _no_options -> []
    end
  end

  @doc """
  The latest finished tasks of `pipeline` (succeeded, failed or canceled),
  newest first, each with its stage runs (and their jobs) and decisions: how
  the pipeline has worked, for improving it.
  """
  @spec history(Pipeline.t(), pos_integer()) :: [Task.t()]
  def history(%Pipeline{id: pipeline_id}, limit \\ 20) do
    runs = from r in attempts_query(), preload: :job
    decisions = from d in Decision, order_by: [asc: d.inserted_at]

    Repo.all(
      from t in Task,
        where: t.pipeline_id == ^pipeline_id and t.status in [:succeeded, :failed, :canceled],
        order_by: [desc: t.finished_at, desc: t.inserted_at],
        limit: ^limit,
        preload: [stage_runs: ^runs, decisions: ^decisions]
    )
  end

  @doc "The decisions taken on a task, oldest first."
  @spec list_decisions(Task.t()) :: [Decision.t()]
  def list_decisions(%Task{id: task_id}) do
    Repo.all(
      from d in Decision,
        where: d.task_id == ^task_id,
        order_by: [asc: d.inserted_at, asc: d.id],
        preload: :decided_by_user
    )
  end

  @doc """
  Runs the current stage again, with the person's instructions (and the
  option chosen, if any).
  """
  @spec retry_stage(Task.t(), String.t() | nil, decision_opts()) ::
          {:ok, Task.t()} | {:error, :not_awaiting}
  def retry_stage(%Task{} = task, instructions, opts \\ []) do
    decide(task, :retry, instructions, Keyword.delete(opts, :answers), &retry/3)
  end

  # In a group, the stages that did not pass run again (all, if they all did).
  defp retry(task, instructions, answers) do
    pending =
      for i <- step(task, task.current_stage),
          latest_run(task, i) |> then(&(&1 == nil or &1.status != :passed)),
          do: i

    start_step(
      task,
      task.current_stage,
      instructions,
      if(pending == [], do: nil, else: pending),
      answers
    )
  end

  @doc """
  Answers the questionnaire of the pause ("Responder e continuar"): every
  question must be answered (`Questionnaire.validate_answers/2`). The
  decision keeps the questions and answers, and the stage runs again (the
  stages of the group that did not pass), its agent given them in its
  prompt.
  """
  @spec answer(Task.t(), [Questionnaire.answer()] | nil, String.t() | nil, decision_opts()) ::
          {:ok, Task.t()} | {:error, :not_awaiting} | {:error, :invalid_answers, String.t()}
  def answer(%Task{} = task, answers, instructions, opts \\ []) do
    case Repo.get!(Task, task.id) do
      %Task{status: :awaiting_decision, decision_questionnaire: %{"perguntas" => questions}} ->
        case Questionnaire.validate_answers(questions, answers) do
          {:ok, answers} ->
            decide(task, :retry, instructions, Keyword.put(opts, :answers, answers), &retry/3)

          {:error, reason} ->
            {:error, :invalid_answers, reason}
        end

      %Task{status: :awaiting_decision} ->
        {:error, :invalid_answers, "Esta pausa não tem perguntas."}

      _not_awaiting ->
        {:error, :not_awaiting}
    end
  end

  @doc """
  Moves on to the next stage (the task succeeds if there is none), giving it
  the person's instructions (and the option chosen, if any). `:answers`, to
  the pause's questionnaire, may leave questions unanswered
  (`Questionnaire.validate_partial/2`); the next stage gets them. None
  answered is the same as no answers.
  """
  @spec advance(Task.t(), String.t() | nil, decision_opts()) ::
          {:ok, Task.t()} | {:error, :not_awaiting} | {:error, :invalid_answers, String.t()}
  def advance(%Task{} = task, instructions, opts \\ []) do
    with {:ok, opts} <- partial_answers(task, opts) do
      decide(
        task,
        :advance,
        instructions,
        opts,
        &next_or_finish(&1, step_last(&1, &1.current_stage) + 1, &2, &3)
      )
    end
  end

  defp partial_answers(task, opts) do
    with answers when is_list(answers) <- opts[:answers],
         true <- Enum.any?(answers, &Questionnaire.answered?/1),
         %Task{decision_questionnaire: %{"perguntas" => questions}} <- Repo.get!(Task, task.id) do
      case Questionnaire.validate_partial(questions, answers) do
        {:ok, answers} -> {:ok, Keyword.put(opts, :answers, answers)}
        {:error, reason} -> {:error, :invalid_answers, reason}
      end
    else
      _no_answers -> {:ok, Keyword.delete(opts, :answers)}
    end
  end

  # ── Talking to a task ─────────────────────────────────────────────────────

  @doc """
  Sends instructions to a task that has not ended. They wait for its next
  attempt or stage (one running now is not interrupted), added to any sent
  before.
  """
  @spec instruct(Task.t(), String.t()) :: {:ok, Task.t()} | {:error, :blank | :finished}
  def instruct(%Task{} = task, text) do
    task = Repo.get!(Task, task.id)

    cond do
      blank_to_nil(text) == nil ->
        {:error, :blank}

      not Task.active?(task) ->
        {:error, :finished}

      true ->
        pending = join_instructions([task.pending_instructions, text])
        update_and_notify(task, pending_instructions: pending)
    end
  end

  @doc "Asks a running task to pause for a decision once its current stage ends."
  @spec request_pause(Task.t()) :: {:ok, Task.t()} | {:error, :not_running}
  def request_pause(%Task{} = task) do
    case Repo.get!(Task, task.id) do
      %Task{status: :running} = task -> update_and_notify(task, pause_requested: true)
      _other -> {:error, :not_running}
    end
  end

  @typedoc """
  How a stage is run again by hand: who asked (`:by`), on which runner
  (`:runner_id`, the task's own when absent) and whether that runner is
  online (`:runner_online?`, for stopping a job it cannot confirm).
  """
  @type rerun_opts :: [
          by: User.t() | nil,
          via: String.t() | nil,
          runner_id: String.t() | nil,
          runner_online?: boolean(),
          merge_fix: boolean()
        ]

  @typedoc "Why a task's stage could not be run again."
  @type rerun_error :: :running | :active | :no_stage | :blank | :removing | :runner

  @doc """
  Runs a task again from stage `index`: a new attempt of that stage, with
  `instructions`, then the stages after it as usual. For a task that is not
  running. A worktree removed is made again by the runner, from the task's
  branch. With `:runner_id`, the task goes on in that runner
  (`switch_runner/2`).
  """
  @spec redo_from(Task.t(), non_neg_integer(), String.t() | nil, rerun_opts()) ::
          {:ok, Task.t()} | {:error, rerun_error()}
  def redo_from(%Task{} = task, index, instructions, opts \\ []) do
    task = Repo.get!(Task, task.id)

    cond do
      task.status == :running ->
        {:error, :running}

      index not in 0..(length(task.stages) - 1)//1 ->
        {:error, :no_stage}

      true ->
        with {:ok, task} <- reopen(task, opts[:runner_id]) do
          analysis = task.decision_analysis_job_id

          task =
            task |> start_step(step_first(task, index), instructions) |> preload()

          cancel_analysis(analysis)
          notify(task)
          {:ok, task}
        end
    end
  end

  @correction_prompt """
  Esta tarefa já passou pelas etapas do pipeline. Foi pedida uma correção: ela está nas instruções abaixo e é o objetivo desta etapa.

  # O que fazer
  1. Entenda onde a tarefa está: leia os artefatos das etapas anteriores e veja a branch (`git status`, `git fetch origin` e `git log --oneline origin/main..HEAD`).
  2. Faça o que foi pedido, e só isso. Se o pedido não for possível ou faltar informação, termine como "bloqueado" e pergunte.
  3. Valide como o pipeline valida: rode os testes e o lint do projeto, se houver ({{projeto.teste}} {{projeto.lint}}), e corrija até passar.
  4. No artefato, diga o que mudou e como validou.

  """

  @doc """
  Runs a person's `prompt` in a task that ended (succeeded, failed or
  canceled), in its worktree and branch: a stage "Correção N" is added at the
  end of the task, with the gates, attempts, model and timeout of its last
  stage, and runs like any stage (gates, delivery, decisions). Options as in
  `redo_from/4`, plus `merge_fix: true` when it fixes what kept the platform
  from merging the pull request (`PipeMaestro.Integrations.AutoMerge`): the
  task counts it in `merge_fixes` and is `"fixing"` until it succeeds again.
  A person's correction leaves the merge to be worked out again then.
  """
  @spec correct(Task.t(), String.t() | nil, rerun_opts()) ::
          {:ok, Task.t()} | {:error, rerun_error()}
  def correct(%Task{} = task, prompt, opts \\ []) do
    task = Repo.get!(Task, task.id)

    cond do
      blank_to_nil(prompt) == nil ->
        {:error, :blank}

      Task.active?(task) ->
        {:error, :active}

      true ->
        with {:ok, task} <- reopen(task, opts[:runner_id]) do
          index = length(task.stages)
          stage = correction_stage(task)

          task =
            task
            |> Ecto.Changeset.change(correction_merge_fields(task, opts[:merge_fix]))
            |> Ecto.Changeset.put_embed(:stages, task.stages ++ [stage])
            |> Repo.update!()

          Repo.insert!(%Decision{
            task_id: task.id,
            stage_index: index,
            action: :correct,
            instructions: String.trim(prompt),
            decided_by_user_id: opts[:by] && opts[:by].id,
            decided_via: opts[:via]
          })

          Audit.record(task.workspace_id, opts[:by], "task.corrected", task, %{
            "stage" => stage.name
          })

          task = task |> start_step(index, prompt) |> preload()
          notify(task)
          {:ok, task}
        end
    end
  end

  defp correction_merge_fields(task, true),
    do: [
      merge_state: "fixing",
      merge_fixes: task.merge_fixes + 1,
      merge_reason: nil,
      merge_waiting_since: nil
    ]

  defp correction_merge_fields(_task, _merge_fix),
    do: [merge_state: nil, merge_reason: nil, merge_waiting_since: nil]

  @doc """
  Has the platform try again to merge the pull request of a task whose merge
  was blocked: it waits for the host's checks again, with its corrections
  counted from zero.
  """
  @spec retry_merge(Task.t(), User.t() | nil) :: {:ok, Task.t()} | {:error, :not_blocked}
  def retry_merge(%Task{} = task, by) do
    case Repo.get!(Task, task.id) do
      %Task{status: :succeeded, merge_state: "blocked"} = task ->
        Audit.record(task.workspace_id, by, "task.merge_retried", task)

        task =
          task
          |> Ecto.Changeset.change(merge_fields(task, :succeeded))
          |> Ecto.Changeset.change(merge_fixes: 0)
          |> Repo.update!()
          |> preload()

        notify(task)
        {:ok, task}

      _other ->
        {:error, :not_blocked}
    end
  end

  @doc """
  Records what the platform found trying to merge a task's pull request:
  `attrs` among `merge_state`, `merge_reason` (`PipeMaestro.Integrations.AutoMerge`).
  A merge done or blocked tells the task's people.
  """
  @spec put_merge(Task.t(), map()) :: Task.t()
  def put_merge(%Task{} = task, attrs) do
    task =
      task
      |> Ecto.Changeset.change(Map.take(attrs, [:merge_state, :merge_reason]))
      |> Repo.update!()
      |> preload()

    case attrs[:merge_state] do
      "merged" ->
        Audit.record(task.workspace_id, nil, "task.merged", task)
        Notifications.notify_task(task, :merged)

      "blocked" ->
        Audit.record(task.workspace_id, nil, "task.merge_blocked", task, %{
          "reason" => task.merge_reason
        })

        Notifications.notify_task(task, :merge_blocked)

      _other ->
        []
    end

    notify(task)
    task
  end

  defp correction_stage(task) do
    last = List.last(task.stages)
    n = Enum.count(task.stages, &String.starts_with?(&1.key, "correcao-")) + 1

    %Stage{
      key: "correcao-#{n}",
      name: "Correção #{n}",
      prompt: @correction_prompt,
      max_attempts: last.max_attempts,
      model: last.model,
      max_budget_usd: last.max_budget_usd,
      timeout_minutes: last.timeout_minutes,
      gates: last.gates,
      rules: []
    }
  end

  @doc """
  Stops the stage a task is running and has it wait for a person, who
  decides as after any pause (run it again with instructions, move on,
  cancel). With `runner_online?: false` the job ends at once
  (`PipeMaestro.Jobs.abandon/2`).
  """
  @spec interrupt(Task.t(), rerun_opts()) :: {:ok, Task.t()} | {:error, :not_running}
  def interrupt(%Task{} = task, opts \\ []) do
    case Repo.get!(Task, task.id) do
      %Task{status: :running} = task ->
        Audit.record(task.workspace_id, opts[:by], "task.interrupted", task)
        task = task |> Ecto.Changeset.change(pause_requested: true) |> Repo.update!()
        stop_jobs(task, opts)
        task = Repo.get!(Task, task.id) |> preload()
        notify(task)
        {:ok, task}

      _other ->
        {:error, :not_running}
    end
  end

  defp stop_jobs(task, opts) do
    for job <- running_jobs(task) do
      if opts[:runner_online?] == false,
        do: Jobs.abandon(job, "Interrompido com o runner offline."),
        else: Jobs.request_cancel(job)
    end
  end

  @doc """
  The runners a task may go on in: the workspace's active runners that offer
  its directory. Another runner than the task's own is only offered when the
  task's branch is on `origin` (`switchable?/1`), where the new runner gets
  it from.
  """
  @spec runner_choices(Task.t()) :: [Runner.t()]
  def runner_choices(%Task{} = task) do
    switchable? = switchable?(task)

    Repo.all(
      from r in Runner,
        where: r.workspace_id == ^task.workspace_id and is_nil(r.revoked_at),
        order_by: r.name
    )
    |> Enum.filter(fn runner ->
      runner.id == task.runner_id or
        (switchable? and Enum.any?(runner.directories, &(&1["name"] == task.directory)))
    end)
  end

  @doc """
  Whether a task can go on in another runner: it works in a git worktree and
  its branch was pushed by a delivery, so a new worktree can start from it.
  """
  @spec switchable?(Task.t()) :: boolean()
  def switchable?(%Task{git: true} = task) do
    Repo.exists?(
      from j in Job,
        join: r in StageRun,
        on: r.id == j.stage_run_id,
        where: r.task_id == ^task.id and fragment("(?->>'pushed')::boolean", j.delivery)
    )
  end

  def switchable?(%Task{}), do: false

  # Before a stage runs again by hand: the task moves to another runner if
  # asked, and a worktree removed is forgotten (the runner makes it again).
  # A removal asked for and not done yet could remove the worktree under the
  # new stage, so it is waited for.
  defp reopen(task, runner_id) do
    cond do
      task.worktree_removal_requested_at && is_nil(task.worktree_removed_at) ->
        {:error, :removing}

      runner_id in [nil, "", task.runner_id] ->
        {:ok, forget_removed_worktree(task)}

      true ->
        switch_runner(task, runner_id)
    end
  end

  defp forget_removed_worktree(%Task{worktree_removed_at: nil} = task), do: task

  defp forget_removed_worktree(task) do
    task
    |> Ecto.Changeset.change(
      worktree: nil,
      worktree_removed_at: nil,
      worktree_removal_requested_at: nil,
      worktree_error: nil
    )
    |> Repo.update!()
  end

  defp switch_runner(task, runner_id) do
    if Enum.any?(runner_choices(task), &(&1.id == runner_id)) do
      Audit.record(task.workspace_id, nil, "task.runner_switched", task, %{
        "from" => task.runner_id,
        "to" => runner_id
      })

      {:ok,
       task
       |> Ecto.Changeset.change(
         runner_id: runner_id,
         worktree: nil,
         worktree_removed_at: nil,
         worktree_removal_requested_at: nil,
         worktree_error: nil
       )
       |> Repo.update!()}
    else
      {:error, :runner}
    end
  end

  defp update_and_notify(task, changes) do
    task = task |> Ecto.Changeset.change(changes) |> Repo.update!() |> preload()
    notify(task)
    {:ok, task}
  end

  # The pause is claimed first, in one conditional update: of two people
  # deciding at once, only one gets it, so there is one decision and one job.
  defp decide(task, action, instructions, opts, fun) do
    task = Repo.get!(Task, task.id)

    if task.status == :awaiting_decision and claim(task) do
      choice = blank_to_nil(opts[:choice])
      answers = answered(task, opts[:answers])
      record_decision(task, action, choice, instructions, opts, answers)
      given = join_instructions([choice && "Decisão: #{choice}", instructions])

      task = %{
        task
        | pending_issue_comment: issue_comment(task, action, choice, instructions, answers)
      }

      analysis = task.decision_analysis_job_id
      task = task |> fun.(given, answers) |> preload()
      cancel_analysis(analysis)
      notify(task)
      {:ok, task}
    else
      {:error, :not_awaiting}
    end
  end

  defp claim(task) do
    {count, _} =
      Repo.update_all(
        from(t in Task, where: t.id == ^task.id and t.status == :awaiting_decision),
        set: [status: :running, updated_at: DateTime.utc_now(:second)]
      )

    count == 1
  end

  # The questions and answers of a decision, as the next attempt gets them.
  defp answered(%Task{decision_questionnaire: %{"perguntas" => questions}}, answers)
       when is_list(answers),
       do: %{"perguntas" => questions, "respostas" => answers}

  defp answered(_task, _answers), do: nil

  # Told on the task's issue with the next stage, if it came from one.
  defp issue_comment(%Task{issue_url: nil}, _action, _choice, _instructions, _answers), do: nil

  defp issue_comment(task, action, choice, instructions, answers) do
    stage = Enum.at(task.stages, task.current_stage)
    what = if action == :retry, do: "refazer a etapa", else: "seguir para a próxima etapa"

    [
      "**Decisão na etapa \"#{stage.name}\"**: #{what}.",
      task.decision_reason && "> #{task.decision_reason}",
      answers &&
        "Respostas:\n" <> Questionnaire.to_markdown(answers["perguntas"], answers["respostas"]),
      choice && "Escolha: #{choice}",
      blank_to_nil(instructions) && "Instruções: #{instructions}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n\n")
  end

  # `opts`: who decided (`:by`) and, from a git host, the login there (`:via`).
  defp record_decision(task, action, choice, instructions, opts, answers \\ nil) do
    user = opts[:by]
    run = latest_run(task, task.current_stage)

    if action != :cancel,
      do:
        Audit.record(
          task.workspace_id,
          user,
          "task.decided",
          task,
          %{"action" => to_string(action), "choice" => choice}
          |> Map.merge(if(answers, do: %{"answered" => true}, else: %{}))
        )

    options =
      case run do
        %StageRun{structured_output: %{"opcoes" => options}} when is_list(options) -> options
        _no_options -> []
      end

    Repo.insert!(%Decision{
      task_id: task.id,
      stage_index: task.current_stage,
      question: task.decision_reason,
      options: Enum.filter(options, &is_binary/1),
      action: action,
      choice: choice,
      instructions: blank_to_nil(instructions),
      questions: answers && %{"perguntas" => answers["perguntas"]},
      answers: answers && %{"respostas" => answers["respostas"]},
      decided_by_user_id: user && user.id,
      decided_via: opts[:via]
    })
  end

  defp latest_run(task, index) do
    Repo.one(
      from r in StageRun,
        where: r.task_id == ^task.id and r.index == ^index,
        order_by: [desc: r.attempt, desc: r.requeue],
        limit: 1
    )
  end

  defp last_attempt(task, index) do
    Repo.one(
      from r in StageRun,
        where: r.task_id == ^task.id and r.index == ^index,
        select: max(r.attempt)
    ) || 0
  end

  @doc """
  Cancels a task. A task waiting for a decision ends at once; a running one
  has its job canceled and ends when the runner confirms, or at once when
  `runner_online?: false` (the runner is not there to confirm).
  """
  @spec cancel_task(Task.t(), decision_opts()) :: {:ok, Task.t()} | {:error, :finished}
  def cancel_task(%Task{} = task, opts \\ []) do
    task = Repo.get!(Task, task.id)

    case task.status do
      :queued ->
        Audit.record(task.workspace_id, opts[:by], "task.canceled", task)
        task = task |> finish(:canceled) |> preload()
        notify(task)
        {:ok, task}

      :awaiting_decision ->
        record_decision(task, :cancel, nil, nil, opts)
        Audit.record(task.workspace_id, opts[:by], "task.canceled", task)
        analysis = task.decision_analysis_job_id
        task = task |> finish(:canceled) |> preload()
        cancel_analysis(analysis)
        notify(task)
        {:ok, task}

      :running ->
        Audit.record(task.workspace_id, opts[:by], "task.canceled", task)
        # A pause asked for earlier would turn the cancel into an interruption.
        task |> Ecto.Changeset.change(pause_requested: false) |> Repo.update!()
        stop_jobs(task, opts)
        {:ok, get_task!(%Workspace{id: task.workspace_id}, task.id)}

      _finished ->
        {:error, :finished}
    end
  end

  @doc "Whether a task started from the issue at `url` has not ended yet."
  @spec active_for_issue?(Workspace.t(), String.t()) :: boolean()
  def active_for_issue?(%Workspace{id: workspace_id}, url) do
    Repo.exists?(
      from t in Task,
        where:
          t.workspace_id == ^workspace_id and t.issue_url == ^url and
            t.status in [:queued, :running, :awaiting_decision]
    )
  end

  @doc """
  Starts a task from an issue of a linked repository (`%{"title", "body",
  "html_url"}`, `number`) with a trigger that goes straight to the task: the
  trigger's pipeline, on the project the repository is linked to (its
  runner, waiting for it when offline), on behalf of the trigger's person.
  """
  @spec create_from_linked_issue(Workspace.t(), LinkedRepo.t(), Trigger.t(), map()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t() | :no_acting_user}
  def create_from_linked_issue(
        %Workspace{} = workspace,
        %LinkedRepo{} = repo,
        %Trigger{} = trigger,
        issue
      ) do
    case trigger.acting_user_id && Repo.get(User, trigger.acting_user_id) do
      %User{} = user ->
        body = blank_to_nil(issue["body"]) || issue["title"]

        create_task(
          user,
          workspace,
          %{
            "title" => String.slice(issue["title"] || "Issue", 0, 120),
            "prompt" => "#{body}\n\nIssue: #{issue["html_url"]}",
            "pipeline_id" => trigger.pipeline_id,
            "project_id" => repo.project_id,
            "issue_url" => issue["html_url"]
          },
          issue: %{linked_repo_id: repo.id, issue_number: issue["number"]}
        )

      _nobody ->
        {:error, :no_acting_user}
    end
  end

  @doc """
  What a new task like `task` starts from: the same request, pipeline and
  project (to change before starting it).
  """
  @spec duplicate_params(Task.t()) :: map()
  def duplicate_params(%Task{} = task) do
    %{
      "title" => task.title,
      "prompt" => task.prompt,
      "pipeline_id" => task.pipeline_id,
      "project_id" => task.project_id
    }
  end

  @doc """
  Starts a new task with the same request as `task`, by `user`. It uses the
  pipeline and the project as they are now, so it fails if either is gone.
  """
  @spec rerun(User.t(), Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def rerun(%User{}, %Task{project_id: nil} = task) do
    task
    |> duplicate_params()
    |> change_task()
    |> Map.update!(:errors, &Keyword.delete(&1, :project_id))
    |> Ecto.Changeset.add_error(:project_id, "o projeto não existe mais")
    |> Ecto.Changeset.apply_action(:insert)
  end

  def rerun(%User{} = user, %Task{} = task),
    do: create_task(user, %Workspace{id: task.workspace_id}, duplicate_params(task))

  # ── The worktree ──────────────────────────────────────────────────────────

  @doc """
  Asks the task's runner to remove the task's worktree. Only for a task that
  has ended and has a worktree still there.
  """
  @spec remove_worktree(Task.t()) :: {:ok, Task.t()} | {:error, :active | :no_worktree}
  def remove_worktree(%Task{} = task) do
    task = Repo.get!(Task, task.id)

    cond do
      Task.active?(task) ->
        {:error, :active}

      is_nil(task.worktree) or not is_nil(task.worktree_removed_at) ->
        {:error, :no_worktree}

      true ->
        task =
          task
          |> Ecto.Changeset.change(worktree_removal_requested_at: now(), worktree_error: nil)
          |> Repo.update!()
          |> preload()

        Jobs.tell_runner(task.runner_id, {:worktree_remove, removal(task)})
        notify(task)
        {:ok, task}
    end
  end

  @doc "The removals the runner was asked for and has not confirmed, to send again."
  @spec pending_worktree_removals(Runner.t()) :: [Task.t()]
  def pending_worktree_removals(%Runner{id: runner_id}) do
    Repo.all(
      from t in Task,
        where:
          t.runner_id == ^runner_id and not is_nil(t.worktree_removal_requested_at) and
            is_nil(t.worktree_removed_at)
    )
  end

  @doc "What the runner is sent to remove a task's worktree (`worktree:remove`)."
  @spec removal(Task.t()) :: map()
  def removal(%Task{} = task), do: %{"task_id" => task.id, "directory" => task.directory}

  @doc "The runner removed a task's worktree, or could not (`error`)."
  @spec worktree_removed(Runner.t(), String.t(), String.t() | nil) ::
          {:ok, Task.t()} | {:error, :not_found}
  def worktree_removed(%Runner{id: runner_id}, task_id, error) do
    with {:ok, id} <- Ecto.UUID.cast(task_id),
         %Task{} = task <- Repo.get_by(Task, id: id, runner_id: runner_id) do
      changes =
        if error,
          do: [worktree_error: error, worktree_removal_requested_at: nil],
          else: [worktree_removed_at: now(), worktree_error: nil]

      task = task |> Ecto.Changeset.change(changes) |> Repo.update!() |> preload()
      notify(task)
      {:ok, task}
    else
      _missing -> {:error, :not_found}
    end
  end

  # Every stage of a group may be running.
  defp running_jobs(task) do
    Repo.all(
      from j in Job,
        join: r in StageRun,
        on: r.id == j.stage_run_id,
        where: r.task_id == ^task.id and r.status == :running
    )
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp now, do: DateTime.utc_now(:second)
end
