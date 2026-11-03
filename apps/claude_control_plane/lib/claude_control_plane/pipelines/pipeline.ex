defmodule ClaudeControlPlane.Pipelines.Pipeline do
  @moduledoc """
  A workspace's pipeline: ordered stages a task goes through. Generic on
  purpose, so any project of the workspace can use it; what is specific to a
  project lives in the project's own repository (`CLAUDE.md`, `AGENTS.md`).

  `version` goes up on every save. A task keeps a snapshot of the pipeline it
  started with, so editing one never changes a task already running.
  """
  use ClaudeControlPlane.Schema

  import Ecto.Changeset

  alias ClaudeControlPlane.Pipelines.Stage
  alias ClaudeControlPlane.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          version: pos_integer(),
          stages: [Stage.t()],
          workspace_id: Ecto.UUID.t() | nil,
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @max_stages 20

  schema "pipelines" do
    field :name, :string
    field :description, :string
    field :version, :integer, default: 1

    embeds_many :stages, Stage, on_replace: :delete

    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc """
  Changeset for a pipeline and its stages. Stages come from a form as
  `stages`, with `stages_sort` and `stages_drop` to reorder and remove them.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pipeline, attrs) do
    pipeline
    |> cast(attrs, [:name, :description])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name], message: "dê um nome ao pipeline")
    |> validate_length(:name, max: 80)
    |> validate_length(:description, max: 500)
    |> cast_embed(:stages,
      with: &Stage.changeset/2,
      sort_param: :stages_sort,
      drop_param: :stages_drop
    )
    |> validate_stages()
    |> unsafe_validate_unique([:workspace_id, :name], ClaudeControlPlane.Repo,
      error_key: :name,
      message: "já existe um pipeline com esse nome"
    )
    |> unique_constraint([:workspace_id, :name],
      error_key: :name,
      message: "já existe um pipeline com esse nome"
    )
  end

  defp validate_stages(changeset) do
    stages = get_field(changeset, :stages)

    cond do
      stages == [] ->
        add_error(changeset, :stages, "adicione ao menos uma etapa")

      length(stages) > @max_stages ->
        add_error(changeset, :stages, "no máximo #{@max_stages} etapas")

      duplicated_keys(stages) != [] ->
        add_error(
          changeset,
          :stages,
          "cada etapa precisa de uma chave própria (repetidas: #{Enum.join(duplicated_keys(stages), ", ")})"
        )

      true ->
        changeset
    end
  end

  defp duplicated_keys(stages) do
    stages
    |> Enum.map(& &1.key)
    |> Enum.frequencies()
    |> Enum.filter(fn {key, count} -> key && count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end
end
