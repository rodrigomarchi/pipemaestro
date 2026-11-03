defmodule ClaudeControlPlane.Runners.DeviceAuthorization do
  @moduledoc """
  A runner's pending sign-in: the CLI holds the secret device code and polls;
  a person types the short user code in the browser and approves it into a
  workspace. Only the device code's hash is stored.
  """
  use ClaudeControlPlane.Schema

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Runners.Runner
  alias ClaudeControlPlane.Workspaces.Workspace

  @type status :: :pending | :approved | :denied | :consumed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          device_code_hash: binary() | nil,
          user_code: String.t() | nil,
          status: status(),
          requested: map(),
          name: String.t() | nil,
          expires_at: DateTime.t() | nil,
          last_polled_at: DateTime.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          approved_by_user_id: Ecto.UUID.t() | nil,
          runner_id: Ecto.UUID.t() | nil,
          runner: Runner.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "runner_device_authorizations" do
    field :device_code_hash, :binary, redact: true
    field :user_code, :string
    field :status, Ecto.Enum, values: [:pending, :approved, :denied, :consumed], default: :pending
    field :requested, :map, default: %{}
    field :name, :string
    field :expires_at, :utc_datetime
    field :last_polled_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :approved_by_user, User
    belongs_to :runner, Runner

    timestamps()
  end
end
