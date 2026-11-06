defmodule PipeMaestro.Integrations.LinkedRepo do
  @moduledoc """
  A repository of a connection linked to one of the workspace's projects: its
  issues may start tasks in the project's directory (`PipeMaestro.Integrations.Trigger`).

  - `webhook_status`: `"managed"` when the platform created the webhook
    (`webhook_id`), `"manual"` when someone must create it with the URL and the
    secret, `"failed"` when creating it failed for another reason.
  - `label_prefix`: the platform's labels on the repository
    (`PipeMaestro.Integrations.Labels`).
  - `synced_at`: where the next reconciliation starts reading issues.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Integrations.{Connection, Trigger}
  alias PipeMaestro.Projects.Project

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          owner: String.t() | nil,
          name: String.t() | nil,
          full_name: String.t() | nil,
          external_id: String.t() | nil,
          default_branch: String.t() | nil,
          webhook_id: String.t() | nil,
          webhook_status: String.t(),
          label_prefix: String.t(),
          synced_at: DateTime.t() | nil,
          connection_id: Ecto.UUID.t() | nil,
          connection: Connection.t() | Ecto.Association.NotLoaded.t(),
          workspace_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t() | nil,
          triggers: [Trigger.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "integration_repos" do
    field :owner, :string
    field :name, :string
    field :full_name, :string
    field :external_id, :string
    field :default_branch, :string
    field :webhook_id, :string
    field :webhook_status, :string, default: "manual"
    field :label_prefix, :string, default: "pipemaestro"
    field :synced_at, :utc_datetime
    field :workspace_id, :binary_id

    belongs_to :connection, Connection
    belongs_to :project, Project
    has_many :triggers, Trigger, foreign_key: :repo_id

    timestamps()
  end

  @doc """
  Changeset for the repository's name, project and label prefix. The project
  is required: it decides where the repository's issues run.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(repo, attrs) do
    repo
    |> cast(attrs, [:full_name, :project_id, :label_prefix])
    |> update_change(:full_name, &String.downcase(String.trim(&1)))
    |> validate_required([:full_name], message: "escolha o repositório")
    |> validate_required([:project_id],
      message: "escolha o projeto: é nele que as issues viram tarefas"
    )
    |> validate_format(:full_name, ~r{^[\w.-]+/[\w.-]+$}, message: "use dono/repositório")
    |> validate_format(:label_prefix, ~r/^[a-z0-9][a-z0-9._-]{0,29}$/,
      message: "use letras minúsculas, números, ponto, hífen ou _"
    )
    |> split_full_name()
    |> unique_constraint(:full_name,
      name: :integration_repos_connection_id_full_name_index,
      message: "já está vinculado"
    )
  end

  @doc "What the host said about the repository and its webhook."
  @spec host_changeset(t(), map()) :: Ecto.Changeset.t()
  def host_changeset(repo, attrs),
    do:
      cast(repo, attrs, [:external_id, :default_branch, :webhook_id, :webhook_status, :synced_at])

  defp split_full_name(%{valid?: true} = changeset) do
    case get_change(changeset, :full_name) do
      nil ->
        changeset

      full_name ->
        [owner, name] = String.split(full_name, "/")
        changeset |> put_change(:owner, owner) |> put_change(:name, name)
    end
  end

  defp split_full_name(changeset), do: changeset
end
