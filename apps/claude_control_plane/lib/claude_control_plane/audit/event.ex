defmodule ClaudeControlPlane.Audit.Event do
  @moduledoc """
  Something a person did in a workspace: who (`actor_user`), what (`action`,
  such as `"task.created"` or `"pipeline.saved"`), on what (`subject_type`,
  `subject_id` and its name at the time) and any `details`.
  """
  use ClaudeControlPlane.Schema

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          action: String.t() | nil,
          subject_type: String.t() | nil,
          subject_id: Ecto.UUID.t() | nil,
          subject_name: String.t() | nil,
          details: map(),
          workspace_id: Ecto.UUID.t() | nil,
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          actor_user_id: Ecto.UUID.t() | nil,
          actor_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "audit_events" do
    field :action, :string
    field :subject_type, :string
    field :subject_id, :binary_id
    field :subject_name, :string
    field :details, :map, default: %{}

    belongs_to :workspace, Workspace
    belongs_to :actor_user, User

    # Microseconds: events are listed in the order they happened.
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
