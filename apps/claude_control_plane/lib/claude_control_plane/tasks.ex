defmodule ClaudeControlPlane.Tasks do
  @moduledoc """
  Tasks: a prompt worked through a pipeline, stage by stage, on one runner and
  in one of its directories.

  Each stage attempt is a `ClaudeControlPlane.Tasks.StageRun` run as a job.
  When the job ends, `job_finished/1` applies the gate
  (`ClaudeControlPlane.Tasks.Engine`): the next stage starts, the stage is
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

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Jobs
  alias ClaudeControlPlane.Jobs.Job
  alias ClaudeControlPlane.Pipelines.{Pipeline, Prompt}
  alias ClaudeControlPlane.Projects
  alias ClaudeControlPlane.Projects.Project
  alias ClaudeControlPlane.Repo
  alias ClaudeControlPlane.Runners.Runner
  alias ClaudeControlPlane.Tasks.{Engine, StageRun, Task}
  alias ClaudeControlPlane.Workspaces.Workspace

  @pubsub ClaudeControlPlane.PubSub
  @list_limit 100
  @max_artifact_bytes 65_536

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
        preload: [:runner, :created_by_user]
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
    Repo.preload(task, [:runner, :created_by_user, stage_runs: runs], force: true)
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
      task = task |> put_branch() |> start_stage(0, nil) |> preload()
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
        previous: Enum.take(task.stages, index),
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
      pending_instructions: nil,
      finished_at: nil
    )
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
      "permissions" => permissions(stage, task.project)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Everything goes in a "total" stage; a narrower one also lets the agent run
  # the project's test and lint commands.
  defp permissions(%{permission_profile: "total"}, _project), do: nil

  defp permissions(stage, project) do
    commands =
      for key <- ["test_command", "lint_command"],
          command = project && project[key],
          is_binary(command) and String.trim(command) != "",
          do: "Bash(#{String.trim(command)}:*)"

    %{
      "profile" => stage.permission_profile,
      "allow" => Enum.uniq(stage.allowed_tools ++ commands),
      "deny" => stage.denied_tools
    }
  end

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
  stage produced and applies the gate (`ClaudeControlPlane.Tasks.Engine`).
  """
  @spec job_finished(Job.t()) :: :ok
  def job_finished(%Job{stage_run_id: stage_run_id} = job) when is_binary(stage_run_id) do
    stage_run = Repo.get!(StageRun, stage_run_id)
    task = Repo.get!(Task, stage_run.task_id)

    if Task.active?(task) and stage_run.status == :running do
      stage = Enum.at(task.stages, stage_run.index)
      outcome = Engine.gate(job, stage, stage_run.attempt)

      record_stage_run(stage_run, job, outcome)

      task
      |> maybe_record_worktree(job)
      |> advance_after(stage_run, outcome)
      |> preload()
      |> notify()
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

  defp maybe_record_worktree(%Task{worktree: nil} = task, %Job{workdir: workdir})
       when is_binary(workdir),
       do: task |> Ecto.Changeset.change(worktree: workdir) |> Repo.update!()

  defp maybe_record_worktree(task, _job), do: task

  defp advance_after(task, stage_run, outcome) do
    stage = Enum.at(task.stages, stage_run.index)

    case outcome do
      :passed when task.pause_requested ->
        await(task, "Alguém pediu uma pausa depois da etapa \"#{stage.name}\".")

      :passed when stage.pause_after ->
        await(task, "A etapa \"#{stage.name}\" terminou e pede aprovação para seguir.")

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
      do: start_stage(task, index, instructions, last_attempt(task, index) + 1),
      else: finish(task, :succeeded)
  end

  defp await(task, reason) do
    task
    |> Ecto.Changeset.change(
      status: :awaiting_decision,
      decision_reason: reason,
      pause_requested: false
    )
    |> Repo.update!()
    |> announce(:awaiting)
  end

  defp finish(task, status) do
    task
    |> Ecto.Changeset.change(status: status, decision_reason: nil, finished_at: now())
    |> Repo.update!()
    |> announce(status)
  end

  # ── Decisions ─────────────────────────────────────────────────────────────

  @doc "Runs the current stage again, with the person's instructions."
  @spec retry_stage(Task.t(), String.t() | nil) :: {:ok, Task.t()} | {:error, :not_awaiting}
  def retry_stage(%Task{} = task, instructions) do
    decide(task, fn task ->
      attempt = last_attempt(task, task.current_stage) + 1
      start_stage(task, task.current_stage, instructions, attempt)
    end)
  end

  @doc """
  Moves on to the next stage (the task succeeds if there is none), giving it
  the person's instructions.
  """
  @spec advance(Task.t(), String.t() | nil) :: {:ok, Task.t()} | {:error, :not_awaiting}
  def advance(%Task{} = task, instructions) do
    decide(task, &next_or_finish(&1, &1.current_stage + 1, instructions))
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
          task |> start_stage(index, instructions, last_attempt(task, index) + 1) |> preload()

        notify(task)
        {:ok, task}
    end
  end

  defp update_and_notify(task, changes) do
    task = task |> Ecto.Changeset.change(changes) |> Repo.update!() |> preload()
    notify(task)
    {:ok, task}
  end

  defp decide(task, fun) do
    task = Repo.get!(Task, task.id)

    if task.status == :awaiting_decision do
      task = task |> fun.() |> preload()
      notify(task)
      {:ok, task}
    else
      {:error, :not_awaiting}
    end
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
  @spec cancel_task(Task.t()) :: {:ok, Task.t()} | {:error, :finished}
  def cancel_task(%Task{} = task) do
    task = Repo.get!(Task, task.id)

    case task.status do
      :awaiting_decision ->
        task = task |> finish(:canceled) |> preload()
        notify(task)
        {:ok, task}

      :running ->
        task |> running_job() |> Jobs.request_cancel()
        {:ok, get_task!(%Workspace{id: task.workspace_id}, task.id)}

      _finished ->
        {:error, :finished}
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

  defp running_job(task) do
    Repo.one!(
      from j in Job,
        join: r in StageRun,
        on: r.id == j.stage_run_id,
        where: r.task_id == ^task.id and r.status == :running,
        order_by: [desc: j.inserted_at],
        limit: 1
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
