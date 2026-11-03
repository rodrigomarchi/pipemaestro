defmodule ClaudeControlPlane.Audit do
  @moduledoc """
  The workspace's audit trail (`ClaudeControlPlane.Audit.Event`): who created,
  decided or canceled tasks, saved or removed pipelines and projects, and
  approved, renamed or revoked runners. Kept as long as the retention policy
  says (`prune/1`).
  """

  import Ecto.Query

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Audit.Event
  alias ClaudeControlPlane.Repo
  alias ClaudeControlPlane.Workspaces.Workspace

  @list_limit 200

  @doc """
  Records that `actor` did `action` on `subject` (a struct with an `id` and a
  `title` or `name`) in the workspace.
  """
  @spec record(Workspace.t() | Ecto.UUID.t(), User.t() | nil, String.t(), struct(), map()) :: :ok
  def record(workspace, actor, action, subject, details \\ %{}) do
    Repo.insert!(%Event{
      workspace_id: workspace_id(workspace),
      actor_user_id: actor && actor.id,
      action: action,
      subject_type: subject_type(subject),
      subject_id: Map.get(subject, :id),
      subject_name: Map.get(subject, :title) || Map.get(subject, :name),
      details: details
    })

    :ok
  end

  @doc "The workspace's most recent events, newest first."
  @spec list_events(Workspace.t()) :: [Event.t()]
  def list_events(%Workspace{id: workspace_id}) do
    Repo.all(
      from e in Event,
        where: e.workspace_id == ^workspace_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: @list_limit,
        preload: :actor_user
    )
  end

  @doc "Removes the events older than `before`; returns how many went."
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(before) do
    {count, _rows} = Repo.delete_all(from e in Event, where: e.inserted_at < ^before)
    count
  end

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(id) when is_binary(id), do: id

  # "ClaudeControlPlane.Tasks.Task" -> "task"
  defp subject_type(%module{}),
    do: module |> Module.split() |> List.last() |> Macro.underscore()
end
