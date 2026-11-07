defmodule PipeMaestro.Notifications do
  @moduledoc """
  The notification center of a workspace's people: an inbox of what happened
  (`PipeMaestro.Notifications.Notification`, kept until read and for 30 days
  after) and what is under way now (`PipeMaestro.Notifications.Execution`,
  derived from the tasks and jobs, never stored).

  A task's pause and end (`notify_task/2`) reach its creator and the owner
  of its decision, while they are still members of the workspace; a task
  nobody of the workspace created (one from an issue) reaches the
  workspace's admins. A proposal ready for review (`notify_proposal/1`)
  reaches who asked for it.

  Every read and write takes a scope (`PipeMaestro.Accounts.Scope`): a person
  only sees and marks their own notifications, in the scope's workspace.

  PubSub (`subscribe/1`): the person's topic gets `{:notification, n}` and
  `{:unread_count, count}`; the workspace's activity topic gets
  `{:executions_changed, workspace_id}` whenever a task or a proposal
  changes (`executions_changed/1`), for whoever shows what is running.
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.{Scope, User}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Notifications.{Execution, Notification}
  alias PipeMaestro.Proposals
  alias PipeMaestro.Repo
  alias PipeMaestro.Tasks.{StageRun, Task}
  alias PipeMaestro.Workspaces.{Membership, Workspace}

  @pubsub PipeMaestro.PubSub
  @page 20
  @active_statuses [:running, :awaiting_decision, :queued]

  @typedoc "What a task's event is: `PipeMaestro.Tasks` announces the same kinds."
  @type task_event :: :awaiting | :succeeded | :failed | :canceled

  @typedoc """
  Options of `list_for/2`: `limit` (default 20), `before` (the
  `{inserted_at, id}` of the last one already shown) and `unread: true`.
  """
  @type list_opt ::
          {:limit, pos_integer()}
          | {:before, {DateTime.t(), Ecto.UUID.t()} | nil}
          | {:unread, boolean()}

  @typedoc "The executions under way, by status (`group/1`)."
  @type groups :: %{
          running: [Execution.t()],
          awaiting_decision: [Execution.t()],
          queued: [Execution.t()]
        }

  # ── PubSub ────────────────────────────────────────────────────────────────

  @doc """
  Subscribes the calling process to the person's notifications in the
  scope's workspace and to what runs in that workspace.
  """
  @spec subscribe(Scope.t()) :: :ok | {:error, term()}
  def subscribe(%Scope{user: %User{id: user_id}, workspace: %Workspace{id: workspace_id}}) do
    with :ok <- Phoenix.PubSub.subscribe(@pubsub, user_topic(workspace_id, user_id)) do
      Phoenix.PubSub.subscribe(@pubsub, activity_topic(workspace_id))
    end
  end

  @doc "Tells the workspace that one of its tasks or proposals changed."
  @spec executions_changed(Ecto.UUID.t()) :: :ok | {:error, term()}
  def executions_changed(workspace_id),
    do:
      Phoenix.PubSub.broadcast(
        @pubsub,
        activity_topic(workspace_id),
        {:executions_changed, workspace_id}
      )

  defp user_topic(workspace_id, user_id), do: "notifications:user:#{workspace_id}:#{user_id}"
  defp activity_topic(workspace_id), do: "notifications:activity:" <> workspace_id

  # ── Creating ──────────────────────────────────────────────────────────────

  @doc """
  Notifies the people of a task that it paused for a decision (`:awaiting`)
  or ended (`:succeeded`, `:failed`, `:canceled`).
  """
  @spec notify_task(Task.t(), task_event()) :: [Notification.t()]
  def notify_task(%Task{} = task, event) do
    {kind, title} = task_text(task, event)

    create(task.workspace_id, recipients_for_task(task), %{
      kind: kind,
      title: title,
      body: if(event == :awaiting, do: task.decision_reason),
      task_id: task.id
    })
  end

  defp task_text(task, :awaiting), do: {:task_awaiting_decision, "#{task.title} aguarda decisão"}
  defp task_text(task, :succeeded), do: {:task_succeeded, "#{task.title} foi concluída"}
  defp task_text(task, :failed), do: {:task_failed, "#{task.title} falhou"}
  defp task_text(task, :canceled), do: {:task_canceled, "#{task.title} foi cancelada"}

  @doc """
  Who hears of a task: its creator and the owner of its decision, those still
  members of the workspace; when none is, the workspace's admins.
  """
  @spec recipients_for_task(Task.t()) :: [Ecto.UUID.t()]
  def recipients_for_task(%Task{} = task) do
    candidates =
      Enum.uniq(Enum.reject([task.created_by_user_id, task.decision_owner_id], &is_nil/1))

    case members(task.workspace_id, candidates) do
      [] -> admins(task.workspace_id)
      members -> members
    end
  end

  @doc "Notifies who asked for a proposal that it is ready for review."
  @spec notify_proposal(Job.t()) :: [Notification.t()]
  def notify_proposal(%Job{} = job) do
    recipients =
      if job.created_by_user_id,
        do: members(job.workspace_id, [job.created_by_user_id]),
        else: []

    create(job.workspace_id, recipients, %{
      kind: :proposal_ready,
      title: "Proposta pronta para revisão: " <> Proposals.title(job),
      body: nil,
      job_id: job.id
    })
  end

  defp members(_workspace_id, []), do: []

  defp members(workspace_id, user_ids) do
    found =
      Repo.all(
        from m in Membership,
          where: m.workspace_id == ^workspace_id and m.user_id in ^user_ids,
          select: m.user_id
      )

    Enum.filter(user_ids, &(&1 in found))
  end

  defp admins(workspace_id) do
    Repo.all(
      from m in Membership,
        where: m.workspace_id == ^workspace_id and m.role == :admin,
        order_by: m.inserted_at,
        select: m.user_id
    )
  end

  defp create(_workspace_id, [], _attrs), do: []

  defp create(workspace_id, user_ids, attrs) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(user_ids, fn user_id ->
        attrs
        |> Map.merge(%{workspace_id: workspace_id, user_id: user_id})
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)

    {_count, notifications} = Repo.insert_all(Notification, entries, returning: true)

    Enum.each(notifications, fn n ->
      topic = user_topic(workspace_id, n.user_id)
      Phoenix.PubSub.broadcast(@pubsub, topic, {:notification, n})
      Phoenix.PubSub.broadcast(@pubsub, topic, {:unread_count, unread(workspace_id, n.user_id)})
    end)

    notifications
  end

  # ── Reading and marking ───────────────────────────────────────────────────

  @doc """
  The person's notifications in the scope's workspace, newest first
  (`t:list_opt/0`).
  """
  @spec list_for(Scope.t(), [list_opt()]) :: [Notification.t()]
  def list_for(%Scope{} = scope, opts \\ []) do
    scope
    |> scoped()
    |> order_by([n], desc: n.inserted_at, desc: n.id)
    |> limit(^Keyword.get(opts, :limit, @page))
    |> before(opts[:before])
    |> unread_only(opts[:unread])
    |> Repo.all()
  end

  defp before(query, nil), do: query

  defp before(query, {%DateTime{} = at, id}),
    do: where(query, [n], n.inserted_at < ^at or (n.inserted_at == ^at and n.id < ^id))

  defp unread_only(query, true), do: where(query, [n], is_nil(n.read_at))
  defp unread_only(query, _all), do: query

  @doc "How many of the person's notifications in the scope's workspace are unread."
  @spec count_unread(Scope.t()) :: non_neg_integer()
  def count_unread(%Scope{user: %User{id: user_id}, workspace: %Workspace{id: workspace_id}}),
    do: unread(workspace_id, user_id)

  defp unread(workspace_id, user_id) do
    Repo.aggregate(
      from(n in Notification,
        where: n.user_id == ^user_id and n.workspace_id == ^workspace_id and is_nil(n.read_at)
      ),
      :count
    )
  end

  @doc """
  Marks one of the person's notifications as read and tells the new count.
  Another person's, another workspace's or an unknown id is `:not_found`.
  """
  @spec mark_read(Scope.t(), Ecto.UUID.t()) :: {:ok, Notification.t()} | {:error, :not_found}
  def mark_read(%Scope{} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Notification{} = notification <- scope |> scoped() |> Repo.get(id) do
      notification =
        if notification.read_at,
          do: notification,
          else:
            notification
            |> Ecto.Changeset.change(read_at: DateTime.utc_now(:second))
            |> Repo.update!()

      tell_count(scope)
      {:ok, notification}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "Marks all the person's notifications in the scope's workspace as read."
  @spec mark_all_read(Scope.t()) :: {non_neg_integer(), nil}
  def mark_all_read(%Scope{} = scope) do
    {count, _} =
      scope
      |> scoped()
      |> where([n], is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])

    tell_count(scope)
    {count, nil}
  end

  defp tell_count(%Scope{user: %User{id: user_id}, workspace: %Workspace{id: workspace_id}}) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      user_topic(workspace_id, user_id),
      {:unread_count, unread(workspace_id, user_id)}
    )
  end

  defp scoped(%Scope{user: %User{id: user_id}, workspace: %Workspace{id: workspace_id}}),
    do: from(n in Notification, where: n.user_id == ^user_id and n.workspace_id == ^workspace_id)

  @doc "Removes the notifications read before `before`; returns how many went."
  @spec delete_read_before(DateTime.t()) :: non_neg_integer()
  def delete_read_before(%DateTime{} = before) do
    {count, _} =
      Repo.delete_all(
        from n in Notification, where: not is_nil(n.read_at) and n.read_at < ^before
      )

    count
  end

  # ── What is under way ─────────────────────────────────────────────────────

  @doc """
  What is under way in the workspace, oldest first: its tasks running,
  waiting for a decision or in line, and its proposals being written (an
  analysis of a failure shows as its task, waiting). `mine: user` keeps
  only what that person started.
  """
  @spec active_executions(Workspace.t(), [{:mine, User.t() | nil}]) :: [Execution.t()]
  def active_executions(%Workspace{id: workspace_id}, opts \\ []) do
    creator_id =
      case opts[:mine] do
        %User{id: id} -> id
        _everyone -> nil
      end

    (active_tasks(workspace_id, creator_id) ++ active_proposals(workspace_id, creator_id))
    |> Enum.sort_by(& &1.started_at, {:asc, DateTime})
  end

  defp active_tasks(workspace_id, creator_id) do
    last_runs =
      from r in StageRun,
        group_by: r.task_id,
        select: %{task_id: r.task_id, started_at: max(r.inserted_at)}

    from(t in Task,
      left_join: r in subquery(last_runs),
      on: r.task_id == t.id,
      where: t.workspace_id == ^workspace_id and t.status in ^@active_statuses,
      preload: [:runner, :created_by_user],
      select: {t, r.started_at}
    )
    |> by_creator(creator_id)
    |> Repo.all()
    |> Enum.map(fn {task, last_run} ->
      %Execution{
        id: task.id,
        type: :task,
        title: task.title,
        status: task.status,
        stage: task.current_stage + 1,
        stage_count: length(task.stages),
        runner_name: task.runner && task.runner.name,
        started_at: (task.status != :queued && last_run) || task.inserted_at,
        creator_id: task.created_by_user_id,
        creator_name: task.created_by_user && task.created_by_user.name
      }
    end)
  end

  defp active_proposals(workspace_id, creator_id) do
    from(j in Job,
      where:
        j.workspace_id == ^workspace_id and is_nil(j.stage_run_id) and
          j.status in [:queued, :running] and
          fragment("(? -> 'proposal') IS NOT NULL", j.context) and
          fragment("coalesce(? -> 'proposal' ->> 'kind', '') <> 'analysis'", j.context),
      preload: [:runner, :created_by_user]
    )
    |> by_creator(creator_id)
    |> Repo.all()
    |> Enum.map(fn job ->
      %Execution{
        id: job.id,
        type: :proposal,
        title: Proposals.title(job),
        status: job.status,
        runner_name: job.runner && job.runner.name,
        started_at: job.started_at || job.inserted_at,
        creator_id: job.created_by_user_id,
        creator_name: job.created_by_user && job.created_by_user.name,
        proposal_kind: Proposals.kind(job)
      }
    end)
  end

  defp by_creator(query, nil), do: query
  defp by_creator(query, user_id), do: where(query, [x], x.created_by_user_id == ^user_id)

  @doc "Executions split by status: running, waiting for a decision and in line."
  @spec group([Execution.t()]) :: groups()
  def group(executions) do
    groups = Enum.group_by(executions, & &1.status)

    %{
      running: Map.get(groups, :running, []),
      awaiting_decision: Map.get(groups, :awaiting_decision, []),
      queued: Map.get(groups, :queued, [])
    }
  end
end
