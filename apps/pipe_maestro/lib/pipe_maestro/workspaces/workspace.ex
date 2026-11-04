defmodule PipeMaestro.Workspaces.Workspace do
  @moduledoc """
  A customer company: the tenant every pipeline, runner and user belongs to.
  `max_running_tasks` caps how many of its tasks run at once (none when
  `nil`); past it, new tasks wait in line (`PipeMaestro.Tasks`).
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Workspaces.Membership

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          member_count: non_neg_integer() | nil,
          max_running_tasks: pos_integer() | nil,
          users: [User.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :member_count, :integer, virtual: true
    field :max_running_tasks, :integer

    has_many :memberships, Membership
    many_to_many :users, User, join_through: Membership

    timestamps()
  end

  @doc """
  Changeset for creating or editing a workspace. Without a slug, one is derived
  from the name.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :slug, :max_running_tasks])
    |> validate_number(:max_running_tasks, greater_than: 0, message: "use um número positivo")
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> put_default_slug()
    |> validate_required([:slug])
    |> validate_length(:slug, min: 2, max: 40)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "use letras minúsculas, números e hífens"
    )
    |> unsafe_validate_unique(:slug, PipeMaestro.Repo, message: "já está em uso")
    |> unique_constraint(:slug, message: "já está em uso")
  end

  @doc ~S"""
  A URL slug for `name`: ASCII, lowercase, words joined by hyphens.

      iex> PipeMaestro.Workspaces.Workspace.slugify("Acme Engenharia & Cia")
      "acme-engenharia-cia"
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z0-9\s-]/u, "")
    |> String.downcase()
    |> String.split(~r/[\s-]+/, trim: true)
    |> Enum.join("-")
  end

  defp put_default_slug(changeset) do
    case {get_field(changeset, :slug), get_change(changeset, :name)} do
      {slug, name} when slug in [nil, ""] and is_binary(name) ->
        put_change(changeset, :slug, slugify(name))

      _ ->
        changeset
    end
  end
end
