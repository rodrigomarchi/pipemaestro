defmodule ClaudeControlPlane.Secrets.Secret do
  @moduledoc """
  One of a workspace's secrets: an environment variable for the agents
  (`name`) and its value, encrypted (`ClaudeControlPlane.Secrets`).
  """
  use ClaudeControlPlane.Schema

  alias ClaudeControlPlane.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          encrypted_value: binary() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "workspace_secrets" do
    field :name, :string
    field :encrypted_value, :binary, redact: true

    belongs_to :workspace, Workspace

    timestamps()
  end
end
