defmodule PipeMaestro.Pipelines.Pipeline do
  @moduledoc """
  A workspace's pipeline: ordered stages a task goes through. Generic on
  purpose, so any project of the workspace can use it; what is specific to a
  project lives in the project's own repository (`CLAUDE.md`, `AGENTS.md`).

  It may also carry context for every stage's run: `system_prompt` (appended
  to the agent's system prompt), `mcp_config` (MCP servers, the CLI's
  `--mcp-config` object) and `agents` (subagents a stage may run as, the CLI's
  `--agents` object); a form edits the last two as JSON (`mcp_config_json`,
  `agents_json`). `max_task_cost_usd`, when a person sets it, caps what a task
  may spend: past it, the task pauses for a decision after the stage that
  crossed it. Without it, a task has no cost limit.
  `delivery` is what the runner does with a stage that passed, in a git
  directory: `"none"` (whatever the prompts say), `"commit"` (a commit per
  stage) or `"pr"` (also push the branch and keep a draft pull request,
  ready after the last stage).

  `version` goes up on every save. A task keeps a snapshot of the pipeline it
  started with, so editing one never changes a task already running.
  """
  use PipeMaestro.Schema

  import Ecto.Changeset

  alias PipeMaestro.Pipelines.{Json, Stage}
  alias PipeMaestro.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          version: pos_integer(),
          system_prompt: String.t() | nil,
          mcp_config: map() | nil,
          mcp_config_json: String.t() | nil,
          agents: map() | nil,
          agents_json: String.t() | nil,
          max_task_cost_usd: Decimal.t() | nil,
          delivery: String.t(),
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
    field :system_prompt, :string
    field :mcp_config, :map
    field :mcp_config_json, :string, virtual: true
    field :agents, :map
    field :agents_json, :string, virtual: true
    field :max_task_cost_usd, :decimal
    field :delivery, :string, default: "none"

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
    |> cast(attrs, [
      :name,
      :description,
      :system_prompt,
      :mcp_config_json,
      :agents_json,
      :max_task_cost_usd,
      :delivery
    ])
    |> validate_inclusion(:delivery, ~w(none commit pr), message: "escolha como entregar")
    |> validate_number(:max_task_cost_usd, greater_than: 0, message: "use um valor positivo")
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name], message: "dê um nome ao pipeline")
    |> validate_length(:name, max: 80)
    |> validate_length(:description, max: 500)
    |> validate_length(:system_prompt, max: 8_000)
    |> parse_json(:mcp_config, &mcp_config?/1, ~s(precisa ser um objeto com "mcpServers"))
    |> parse_json(:agents, &is_map/1, "precisa ser um objeto com os agentes por nome")
    |> cast_embed(:stages,
      with: &Stage.changeset/2,
      sort_param: :stages_sort,
      drop_param: :stages_drop
    )
    |> validate_stages()
    |> unsafe_validate_unique([:workspace_id, :name], PipeMaestro.Repo,
      error_key: :name,
      message: "já existe um pipeline com esse nome"
    )
    |> unique_constraint([:workspace_id, :name],
      error_key: :name,
      message: "já existe um pipeline com esse nome"
    )
  end

  @doc "The MCP servers as the form shows them: pretty JSON, or empty."
  @spec mcp_config_json(t()) :: String.t()
  def mcp_config_json(%__MODULE__{mcp_config: nil}), do: ""
  def mcp_config_json(%__MODULE__{mcp_config: config}), do: Json.pretty(config)

  @doc "The agents as the form shows them: pretty JSON, or empty."
  @spec agents_json(t()) :: String.t()
  def agents_json(%__MODULE__{agents: nil}), do: ""
  def agents_json(%__MODULE__{agents: agents}), do: Json.pretty(agents)

  @doc "What a task keeps of the pipeline's context when it starts."
  @spec context(t()) :: map()
  def context(%__MODULE__{} = pipeline) do
    %{
      "system_prompt" => pipeline.system_prompt,
      "mcp_config" => pipeline.mcp_config,
      "agents" => pipeline.agents,
      "max_cost_usd" =>
        pipeline.max_task_cost_usd && Decimal.to_string(pipeline.max_task_cost_usd),
      "delivery" => pipeline.delivery
    }
  end

  defp mcp_config?(%{"mcpServers" => servers}) when is_map(servers), do: true
  defp mcp_config?(_value), do: false

  # A blank text (cast to nil) clears the field; no text leaves it alone.
  defp parse_json(changeset, field, valid?, message) do
    json_field = :"#{field}_json"

    if Map.has_key?(changeset.params || %{}, Atom.to_string(json_field)),
      do: put_json(changeset, field, get_change(changeset, json_field), valid?, message),
      else: changeset
  end

  defp put_json(changeset, field, nil, _valid?, _message), do: put_change(changeset, field, nil)

  defp put_json(changeset, field, json, valid?, message) do
    case JSON.decode(json) do
      {:ok, value} ->
        if valid?.(value),
          do: put_change(changeset, field, value),
          else: add_error(changeset, :"#{field}_json", message)

      {:error, _reason} ->
        add_error(changeset, :"#{field}_json", "JSON inválido")
    end
  end

  defp validate_stages(changeset) do
    stages = get_field(changeset, :stages)

    cond do
      stages == [] ->
        add_error(changeset, :stages, "adicione ao menos uma etapa")

      length(stages) > @max_stages ->
        add_error(changeset, :stages, "no máximo #{@max_stages} etapas")

      match?([%{group: group} | _] when group not in [nil, ""], stages) ->
        add_error(
          changeset,
          :stages,
          "a primeira etapa não pode estar num grupo em paralelo: é ela que prepara o worktree"
        )

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
