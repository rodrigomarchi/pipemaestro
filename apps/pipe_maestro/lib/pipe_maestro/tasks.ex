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

  A task's worktree stays on the runner after the task ends, until someone
  asks for it to go (`remove_worktree/1`): the runner's channel gets
  `{:worktree_remove, removal}` and the runner confirms
  (`worktree_removed/3`).

  Changes are broadcast on PubSub (`subscribe/1`): `{:task, id}` and
  `{:workspace, id}` get `{:task_updated, task}`, and `{:decisions, id}` gets
  `{:pending_decisions, count}`, the workspace's tasks waiting for a decision.
  `{:events, id}` gets `{:task_event, %{id, title, kind, reason}}` when a task
  starts waiting for a decision (`kind: :awaiting`) or ends (`:succeeded`,
  `:failed`, `:canceled`), for notifications.
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Audit
  alias PipeMaestro.Jobs
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Pipelines.{Pipeline, Prompt}
  alias PipeMaestro.Projects
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.{Repo, Runners}
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks.{Decision, Engine, StageRun, Task}
  alias PipeMaestro.Workspaces
  alias PipeMaestro.Workspaces.Workspace

  @pubsub PipeMaestro.PubSub
  @list_limit 100
  @max_artifact_bytes 65_536
  # How long a decision may wait before it is overdue.
  @decision_hours 24

  @typedoc "What a PubSub subscription is about."
  @type subject ::
          {:task, Ecto.UUID.t()}
          | {:workspace, Ecto.UUID.t()}
          | {:decisions, Ecto.UUID.t()}
          | {:events, Ecto.UUID.t()}

  @doc "Subscribes the calling process to a task's or a workspace's task updates."
  @spec subscribe(subject()) :: :ok | {:error, term()}
  def subscribe({:task, id}), do: Phoenix.PubSub.subscribe(@pubsub, "tasks:task:" <> id)
  def subscribe({:workspace, id}), do: Phoenix.PubSub.subscribe(@pubsub, "tasks:workspace:" <> id)
  def subscribe({:decisions, id}), do: Phoenix.PubSub.subscribe(@pubsub, "tasks:decisions:" <> id)
  def subscribe({:events, id}), do: Phoenix.PubSub.subscribe(@pubsub, "tasks:events:" <> id)

  defp announce(%Task{} = task, kind) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "tasks:events:" <> task.workspace_id,
      {:task_event, %{id: task.id, title: task.title, kind: kind, reason: task.decision_reason}}
    )

    task
  end

  defp notify(%Task{} = task) do
    Phoenix.PubSub.broadcast(@pubsub, "tasks:task:" <> task.id, {:task_updated, task})

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
  end

  # ── Reading ───────────────────────────────────────────────────────────────

  @doc """
  The workspace's most recent tasks, newest first. `filters` (blank values
  ignored): `"pipeline"` (its name), `"runner_id"`, `"directory"`, `"user_id"`
  (who created it), `"q"` (text in the title or the prompt).
  """
  @spec list_tasks(Workspace.t(), map()) :: [Task.t()]
  def list_tasks(%Workspace{id: workspace_id}, filters \\ %{}) do
    query =
      from t in Task,
        where: t.workspace_id == ^workspace_id,
        order_by: [desc: t.inserted_at, desc: t.id],
        limit: @list_limit,
        preload: [:runner, :created_by_user]

    filters
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.reduce(query, &filter/2)
    |> Repo.all()
  end

  defp filter({"pipeline", name}, query), do: where(query, [t], t.pipeline_name == ^name)
  defp filter({"directory", dir}, query), do: where(query, [t], t.directory == ^dir)

  defp filter({"q", text}, query) do
    pattern = "%" <> String.replace(text, ~r/([\\%_])/, "\\\\\\1") <> "%"
    where(query, [t], ilike(t.title, ^pattern) or ilike(t.prompt, ^pattern))
  end

  defp filter({key, id}, query) when key in ["runner_id", "user_id"] do
    case {key, Ecto.UUID.cast(id)} do
      {_key, :error} -> where(query, false)
      {"runner_id", {:ok, id}} -> where(query, [t], t.runner_id == ^id)
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

  @doc "The workspace's tasks waiting for a decision, the longest waiting first."
  @spec list_awaiting(Workspace.t()) :: [Task.t()]
  def list_awaiting(%Workspace{id: workspace_id}) do
    Repo.all(
      from t in Task,
        where: t.workspace_id == ^workspace_id and t.status == :awaiting_decision,
        order_by: [asc: t.updated_at, asc: t.id],
        preload: [:runner, :created_by_user, :decision_owner]
    )
  end

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
    runs = from r in StageRun, order_by: [asc: r.index, asc: r.attempt], preload: :job

    Repo.preload(task, [:runner, :created_by_user, :decision_owner, stage_runs: runs],
      force: true
    )
  end

  @doc "A changeset for the new-task form."
  @spec change_task(map()) :: Ecto.Changeset.t()
  def change_task(attrs \\ %{}), do: Task.create_changeset(%Task{}, attrs)

  # ── Starting ──────────────────────────────────────────────────────────────

  @doc """
  Creates a task and starts its first stage. The pipeline, the runner (active)
  and the directory (one the runner announced) must belong to the workspace.
  """
  @spec create_task(User.t(), Workspace.t(), map()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(%User{} = user, %Workspace{} = workspace, attrs) do
    changeset =
      %Task{workspace_id: workspace.id, created_by_user_id: user.id}
      |> Task.create_changeset(attrs)
      |> put_pipeline(workspace)
      |> put_directory(workspace)
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

  defp put_directory(changeset, workspace) do
    runner_id = Ecto.Changeset.get_field(changeset, :runner_id)
    directory = Ecto.Changeset.get_field(changeset, :directory)

    with true <- is_binary(runner_id) and is_binary(directory),
         %Runner{} = runner <- active_runner(workspace, runner_id) do
      case Enum.find(runner.directories, &(&1["name"] == directory)) do
        nil ->
          Ecto.Changeset.add_error(changeset, :directory, "o runner não oferece esse diretório")

        dir ->
          Ecto.Changeset.put_change(changeset, :git, dir["git"] == true)
      end
    else
      false ->
        changeset

      nil ->
        Ecto.Changeset.add_error(changeset, :runner_id, "não é um runner ativo deste workspace")
    end
  end

  # The directory's project, if any, as it is now.
  defp put_project(changeset, workspace) do
    with directory when is_binary(directory) <- Ecto.Changeset.get_field(changeset, :directory),
         %Project{} = project <- Projects.for_directory(workspace, directory) do
      changeset
      |> Ecto.Changeset.put_change(:project_id, project.id)
      |> Ecto.Changeset.put_change(:project, Project.snapshot(project))
    else
      _no_project -> changeset
    end
  end

  defp active_runner(workspace, runner_id) do
    case Ecto.UUID.cast(runner_id) do
      {:ok, id} ->
        Repo.one(
          from r in Runner,
            where: r.id == ^id and r.workspace_id == ^workspace.id and is_nil(r.revoked_at)
        )

      :error ->
        nil
    end
  end

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
  # its job, with the prompt and context the runner needs.
  defp start_stage(%Task{} = task, index, instructions, attempt \\ 1) do
    stage = Enum.at(task.stages, index)
    instructions = join_instructions([instructions, task.pending_instructions])

    stage_run =
      Repo.insert!(%StageRun{
        task_id: task.id,
        index: index,
        key: stage.key,
        name: stage.name,
        attempt: attempt,
        instructions: blank_to_nil(instructions),
        feedback: if(attempt > 1, do: previous_feedback(task, index))
      })

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
        feedback: stage_run.feedback
      })

    Jobs.create_stage_job(%{
      workspace_id: task.workspace_id,
      runner_id: task.runner_id,
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
      decision_owner_id: nil,
      decision_due_at: nil,
      pending_issue_comment: nil,
      finished_at: nil
    )
    # Written even when the struct already says nil (a step clears it first).
    |> Ecto.Changeset.force_change(:pending_instructions, nil)
    |> Repo.update!()
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
          where: r.task_id == ^task.id and r.index == ^index,
          order_by: [desc: r.attempt],
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
      "delivery" => if(not grouped?(task, index), do: delivery(task, stage, index))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # What the runner delivers once the stage passes.
  defp delivery(%Task{git: true, pipeline_context: %{"delivery" => mode}} = task, stage, index)
       when mode in ["commit", "pr"] do
    base = %{"commit_message" => "#{stage.name}: #{task.title}"}

    base =
      if mode == "pr",
        do:
          Map.merge(base, %{
            "push" => true,
            "pr" => %{
              "title" => task.title,
              "body" => pr_body(task, index),
              "ready" => index == length(task.stages) - 1
            }
          }),
        else: base

    if task.issue_url && task.pending_issue_comment,
      do:
        Map.put(base, "issue_comment", %{
          "url" => task.issue_url,
          "body" => task.pending_issue_comment
        }),
      else: base
  end

  defp delivery(_task, _stage, _index), do: nil

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

    _Aberto e atualizado pelo PipeMaestro; os artefatos de cada etapa estão em `.control-plane/#{task.id}/`._
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

      record_stage_run(stage_run, job, outcome)

      task = task |> maybe_record_worktree(job) |> maybe_record_pr(job)

      if grouped?(task, stage_run.index),
        do: task |> after_group_stage(stage_run, outcome) |> preload() |> notify(),
        else: task |> advance_after(stage_run, outcome) |> preload() |> notify()
    end

    :ok
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

  defp maybe_record_pr(task, %Job{delivery: %{"pr_url" => url}}) when is_binary(url),
    do: task |> Ecto.Changeset.change(pr_url: url) |> Repo.update!()

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

      :canceled ->
        finish(task, :canceled)

      {:blocked, reason} ->
        await(task, "A etapa \"#{stage.name}\" está bloqueada: #{reason}")

      {:retry, _error} ->
        start_stage(task, stage_run.index, stage_run.instructions, stage_run.attempt + 1)

      {:exhausted, error} ->
        await(
          task,
          "A etapa \"#{stage.name}\" falhou em #{stage_run.attempt} tentativa(s): #{error}"
        )
    end
  end

  # A stage run again (after a redo) keeps counting its attempts.
  defp next_or_finish(task, index, instructions) do
    if index < length(task.stages),
      do: start_step(task, index, instructions),
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
  defp step(task, index) do
    case group_of(task, index) do
      nil ->
        [index]

      group ->
        same = fn i -> group_of(task, i) == group end

        first =
          index
          |> Stream.iterate(&(&1 - 1))
          |> Enum.take_while(&(&1 >= 0 and same.(&1)))
          |> List.last()

        first
        |> Stream.iterate(&(&1 + 1))
        |> Enum.take_while(&(&1 < length(task.stages) and same.(&1)))
    end
  end

  defp step_first(task, index), do: task |> step(index) |> hd()
  defp step_last(task, index), do: task |> step(index) |> List.last()

  # Starts the stages of the step at `index` (or `only` some of them), every
  # one with the instructions; the task's current stage is the step's first.
  defp start_step(task, index, instructions, only \\ nil) do
    instructions = join_instructions([instructions, task.pending_instructions])
    task = %{task | pending_instructions: nil}

    task =
      Enum.reduce(only || step(task, index), task, fn i, task ->
        start_stage(task, i, instructions, last_attempt(task, i) + 1)
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
      :canceled ->
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

    problems =
      for run <- runs, run.status in [:blocked, :failed] do
        if run.status == :blocked,
          do: "A etapa \"#{run.name}\" está bloqueada: #{run.summary}",
          else: "A etapa \"#{run.name}\" falhou: #{run.error}"
      end

    pauses =
      for run <- runs,
          stage = Enum.at(task.stages, run.index),
          run.status == :passed,
          reason = pause_reason(stage, run),
          do: "A etapa \"#{stage.name}\" terminou, mas #{reason}."

    cond do
      problems != [] -> await(task, Enum.join(problems, " "))
      pauses != [] -> await(task, Enum.join(pauses, " "))
      task.pause_requested -> await(task, "Alguém pediu uma pausa depois deste passo.")
      true -> next_or_finish(task, step_last(task, first) + 1, nil)
    end
  end

  defp pause_reason(stage, run), do: Engine.rule_pause(run.structured_output, stage.rules)

  defp await(task, reason) do
    task
    |> Ecto.Changeset.change(
      status: :awaiting_decision,
      decision_reason: reason,
      pause_requested: false,
      decision_owner_id: task.created_by_user_id,
      decision_due_at: DateTime.add(now(), @decision_hours, :hour)
    )
    |> Repo.update!()
    |> announce(:awaiting)
    |> tap(&start_next_queued(&1.workspace_id))
  end

  defp finish(task, status) do
    task
    |> Ecto.Changeset.change(status: status, decision_reason: nil, finished_at: now())
    |> Repo.update!()
    |> announce(status)
    |> tap(&start_next_queued(&1.workspace_id))
  end

  # ── Decisions ─────────────────────────────────────────────────────────────

  @typedoc """
  Who decided and what they chose: `:by` (the user) and `:choice` (one of the
  options the agent proposed, `options/1`), both optional.
  """
  @type decision_opts :: [by: User.t() | nil, choice: String.t() | nil]

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
    runs = from r in StageRun, order_by: [asc: r.index, asc: r.attempt], preload: :job
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
    decide(task, :retry, instructions, opts, fn task, instructions ->
      # In a group, the stages that did not pass (all, if they all did).
      pending =
        for i <- step(task, task.current_stage),
            latest_run(task, i) |> then(&(&1 == nil or &1.status != :passed)),
            do: i

      start_step(
        task,
        task.current_stage,
        instructions,
        if(pending == [], do: nil, else: pending)
      )
    end)
  end

  @doc """
  Moves on to the next stage (the task succeeds if there is none), giving it
  the person's instructions (and the option chosen, if any).
  """
  @spec advance(Task.t(), String.t() | nil, decision_opts()) ::
          {:ok, Task.t()} | {:error, :not_awaiting}
  def advance(%Task{} = task, instructions, opts \\ []) do
    decide(
      task,
      :advance,
      instructions,
      opts,
      &next_or_finish(&1, step_last(&1, &1.current_stage) + 1, &2)
    )
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

  @doc """
  Runs a task again from stage `index`: a new attempt of that stage, with
  `instructions`, then the stages after it as usual. For a task that is not
  running and still has its worktree.
  """
  @spec redo_from(Task.t(), non_neg_integer(), String.t() | nil) ::
          {:ok, Task.t()} | {:error, :running | :no_worktree | :no_stage}
  def redo_from(%Task{} = task, index, instructions) do
    task = Repo.get!(Task, task.id)

    cond do
      task.status == :running ->
        {:error, :running}

      task.worktree_removed_at != nil ->
        {:error, :no_worktree}

      index not in 0..(length(task.stages) - 1)//1 ->
        {:error, :no_stage}

      true ->
        task =
          task |> start_step(step_first(task, index), instructions) |> preload()

        notify(task)
        {:ok, task}
    end
  end

  defp update_and_notify(task, changes) do
    task = task |> Ecto.Changeset.change(changes) |> Repo.update!() |> preload()
    notify(task)
    {:ok, task}
  end

  defp decide(task, action, instructions, opts, fun) do
    task = Repo.get!(Task, task.id)

    if task.status == :awaiting_decision do
      choice = blank_to_nil(opts[:choice])
      record_decision(task, action, choice, instructions, opts[:by])
      given = join_instructions([choice && "Decisão: #{choice}", instructions])
      task = %{task | pending_issue_comment: issue_comment(task, action, choice, instructions)}

      task = task |> fun.(given) |> preload()
      notify(task)
      {:ok, task}
    else
      {:error, :not_awaiting}
    end
  end

  # Told on the task's issue with the next stage, if it came from one.
  defp issue_comment(%Task{issue_url: nil}, _action, _choice, _instructions), do: nil

  defp issue_comment(task, action, choice, instructions) do
    stage = Enum.at(task.stages, task.current_stage)
    what = if action == :retry, do: "refazer a etapa", else: "seguir para a próxima etapa"

    [
      "**Decisão na etapa \"#{stage.name}\"**: #{what}.",
      task.decision_reason && "> #{task.decision_reason}",
      choice && "Escolha: #{choice}",
      blank_to_nil(instructions) && "Instruções: #{instructions}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n\n")
  end

  defp record_decision(task, action, choice, instructions, user) do
    run = latest_run(task, task.current_stage)

    if action != :cancel,
      do:
        Audit.record(task.workspace_id, user, "task.decided", task, %{
          "action" => to_string(action),
          "choice" => choice
        })

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
      decided_by_user_id: user && user.id
    })
  end

  defp latest_run(task, index) do
    Repo.one(
      from r in StageRun,
        where: r.task_id == ^task.id and r.index == ^index,
        order_by: [desc: r.attempt],
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
  has its job canceled and ends when the runner confirms.
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
        record_decision(task, :cancel, nil, nil, opts[:by])
        Audit.record(task.workspace_id, opts[:by], "task.canceled", task)
        task = task |> finish(:canceled) |> preload()
        notify(task)
        {:ok, task}

      :running ->
        Audit.record(task.workspace_id, opts[:by], "task.canceled", task)
        for job <- running_jobs(task), do: Jobs.request_cancel(job)
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
  Starts a task from a GitHub issue (`"title"`, `"body"`, `"html_url"`) with
  the project's trigger: its pipeline and directory, on `runner_id`, on
  behalf of whoever set the trigger up.
  """
  @spec create_from_issue(Workspace.t(), Project.t(), map(), Ecto.UUID.t()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t() | :no_trigger_user}
  def create_from_issue(%Workspace{} = workspace, %Project{} = project, issue, runner_id) do
    case project.trigger_user_id && Repo.get(User, project.trigger_user_id) do
      %User{} = user ->
        body = blank_to_nil(issue["body"]) || issue["title"]

        create_task(user, workspace, %{
          "title" => String.slice(issue["title"] || "Issue", 0, 120),
          "prompt" => "#{body}\n\nIssue: #{issue["html_url"]}",
          "pipeline_id" => project.trigger_pipeline_id,
          "runner_id" => runner_id,
          "directory" => project.directory,
          "issue_url" => issue["html_url"]
        })

      _nobody ->
        {:error, :no_trigger_user}
    end
  end

  @doc """
  What a new task like `task` starts from: the same request, pipeline, runner
  and directory (to change before starting it).
  """
  @spec duplicate_params(Task.t()) :: map()
  def duplicate_params(%Task{} = task) do
    %{
      "title" => task.title,
      "prompt" => task.prompt,
      "pipeline_id" => task.pipeline_id,
      "runner_id" => task.runner_id,
      "directory" => task.directory
    }
  end

  @doc """
  Starts a new task with the same request as `task`, by `user`. It uses the
  pipeline as it is now, so it fails if the pipeline is gone.
  """
  @spec rerun(User.t(), Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
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
