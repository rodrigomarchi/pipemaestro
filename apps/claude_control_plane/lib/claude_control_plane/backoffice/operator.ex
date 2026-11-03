defmodule ClaudeControlPlane.Backoffice.Operator do
  @moduledoc "A platform operator: signs in to the backoffice, never to a workspace."
  use ClaudeControlPlane.Schema

  import Ecto.Changeset

  alias ClaudeControlPlane.Auth.Credentials

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          password: String.t() | nil,
          hashed_password: String.t() | nil,
          disabled_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "operators" do
    field :email, :string
    field :name, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :disabled_at, :utc_datetime

    timestamps()
  end

  @doc "Changeset for creating an operator."
  @spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(operator, attrs) do
    operator
    |> cast(attrs, [:email, :name, :password])
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
    |> Credentials.validate_email(:operators_email_index)
    |> Credentials.validate_and_hash_password()
  end

  @doc "Changeset that disables (`true`) or re-enables (`false`) the operator."
  @spec disabled_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def disabled_changeset(operator, true),
    do: change(operator, disabled_at: DateTime.utc_now(:second))

  def disabled_changeset(operator, false), do: change(operator, disabled_at: nil)
end
