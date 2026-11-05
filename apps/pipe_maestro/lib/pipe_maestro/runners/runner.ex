defmodule PipeMaestro.Runners.Runner do
  @moduledoc """
  A runner registered to a workspace. It authenticates with a token whose
  SHA-256 is all that is stored; the rest is what it announced on its last
  connection, and the account's usage limits (`rate_limit`) as the last run
  on it saw them.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroProtocol.Hello

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          token_hash: binary() | nil,
          hostname: String.t() | nil,
          os: String.t() | nil,
          arch: String.t() | nil,
          runner_version: String.t() | nil,
          labels: [String.t()],
          capacity: pos_integer(),
          directories: [map()],
          capabilities: [String.t()],
          worktree_usage: map() | nil,
          agent: map() | nil,
          rate_limit: map() | nil,
          last_connected_at: DateTime.t() | nil,
          last_seen_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          approved_by_user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "runners" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :hostname, :string
    field :os, :string
    field :arch, :string
    field :runner_version, :string
    field :labels, {:array, :string}, default: []
    field :capacity, :integer, default: 1
    field :directories, {:array, :map}, default: []
    field :capabilities, {:array, :string}, default: []
    field :worktree_usage, :map
    field :agent, :map
    field :rate_limit, :map
    field :last_connected_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :approved_by_user, User

    timestamps()
  end

  @doc "The directory named `name` among those the runner announced, or `nil`."
  @spec directory(t(), String.t() | nil) :: map() | nil
  def directory(%__MODULE__{directories: directories}, name),
    do: Enum.find(directories || [], &(&1["name"] == name))

  @doc "Whether the runner announced the directory named `name`."
  @spec offers?(t(), String.t() | nil) :: boolean()
  def offers?(%__MODULE__{} = runner, name), do: directory(runner, name) != nil

  @doc "Changeset for the runner's display name."
  @spec name_changeset(t(), map()) :: Ecto.Changeset.t()
  def name_changeset(runner, attrs) do
    runner
    |> cast(attrs, [:name])
    |> update_change(:name, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
  end

  defp trim(nil), do: nil
  defp trim(name), do: String.trim(name)

  @doc "Applies what the runner announced when it connected."
  @spec hello_changeset(t(), Hello.t(), DateTime.t()) :: Ecto.Changeset.t()
  def hello_changeset(runner, %Hello{} = hello, now) do
    change(runner,
      hostname: hello.hostname,
      os: hello.os,
      arch: hello.arch,
      runner_version: hello.runner_version,
      labels: hello.labels,
      capacity: hello.capacity,
      directories: hello.directories,
      capabilities: hello.capabilities,
      agent: hello.agent,
      last_connected_at: now,
      last_seen_at: now
    )
  end
end
