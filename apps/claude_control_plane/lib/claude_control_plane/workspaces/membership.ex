defmodule ClaudeControlPlane.Workspaces.Membership do
  @moduledoc """
  Links a user to a workspace they can sign in to, with their role there:
  `:admin` (also manages the workspace's pipelines, projects and runners) or
  `:member` (`ClaudeControlPlane.Authorization`).
  """
  use ClaudeControlPlane.Schema

  import Ecto.Changeset

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Workspaces.Workspace

  @type role :: :admin | :member
  @type t :: %__MODULE__{}

  schema "workspace_memberships" do
    field :role, Ecto.Enum, values: [:admin, :member], default: :member

    belongs_to :workspace, Workspace
    belongs_to :user, User

    timestamps(updated_at: false)
  end

  @doc "Changeset for linking `user_id` to `workspace_id`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:workspace_id, :user_id, :role])
    |> validate_required([:workspace_id, :user_id])
    |> unique_constraint([:workspace_id, :user_id],
      name: :workspace_memberships_workspace_id_user_id_index,
      message: "já faz parte deste workspace"
    )
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
  end
end
