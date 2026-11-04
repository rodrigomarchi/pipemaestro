defmodule PipeMaestro.Authorization do
  @moduledoc """
  What a workspace member may do, by role (`PipeMaestro.Workspaces.Membership`):

    * everyone runs tasks: starts them, talks to them, decides when they wait,
      and cancels their own;
    * admins also manage the workspace's pipelines, projects and runners
      (approve, rename, revoke) and cancel anyone's task.
  """

  alias PipeMaestro.Accounts.Scope
  alias PipeMaestro.Tasks.Task

  @type action ::
          :run_tasks | :manage_pipelines | :manage_projects | :manage_runners | :cancel_task

  @doc "Whether the scope's user may do `action` (on `subject`, when it matters)."
  @spec can?(Scope.t(), action(), term()) :: boolean()
  def can?(scope, action, subject \\ nil)

  def can?(%Scope{role: role}, _action, _subject) when role not in [:admin, :member], do: false
  def can?(%Scope{}, :run_tasks, _subject), do: true
  def can?(%Scope{role: :admin}, _action, _subject), do: true

  def can?(%Scope{user: user}, :cancel_task, %Task{created_by_user_id: creator}),
    do: creator == user.id

  def can?(%Scope{}, _action, _subject), do: false
end
