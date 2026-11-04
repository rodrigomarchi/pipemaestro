defmodule PipeMaestro.Accounts.User do
  @moduledoc "A person who signs in to one or more workspaces."
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Auth.Credentials
  alias PipeMaestro.Workspaces.{Membership, Workspace}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          password: String.t() | nil,
          hashed_password: String.t() | nil,
          disabled_at: DateTime.t() | nil,
          workspaces: [Workspace.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "users" do
    field :email, :string
    field :name, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :disabled_at, :utc_datetime

    has_many :memberships, Membership
    many_to_many :workspaces, Workspace, join_through: Membership

    timestamps()
  end

  @doc "Changeset for creating a user."
  @spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password])
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
    |> Credentials.validate_email(:users_email_index)
    |> Credentials.validate_and_hash_password()
  end

  @doc "Changeset for setting a new password."
  @spec password_changeset(t(), map()) :: Ecto.Changeset.t()
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> Credentials.validate_and_hash_password()
  end

  @doc "Changeset that disables (`true`) or re-enables (`false`) the user."
  @spec disabled_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def disabled_changeset(user, true), do: change(user, disabled_at: DateTime.utc_now(:second))
  def disabled_changeset(user, false), do: change(user, disabled_at: nil)
end
