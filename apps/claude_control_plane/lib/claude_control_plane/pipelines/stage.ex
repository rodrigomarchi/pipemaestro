defmodule ClaudeControlPlane.Pipelines.Stage do
  @moduledoc """
  One stage of a pipeline: what the agent is asked to do (`prompt`, a template
  over `ClaudeControlPlane.Pipelines.Prompt.variables/0`), how many attempts it
  gets, whether a person must approve it before the next stage, and the
  model, budget, time limit (`timeout_minutes`, past which the runner stops
  the agent and the attempt fails) and extra output fields its run uses.

  `gates` are commands the runner runs after the agent, each expected to pass
  or to fail (a gate not met fails the attempt); `rules` pause the task for a
  person when the structured output says so (`field op value`, `op` `==` or
  `!=`). A form edits both as text, one per line (`gates_text`, a `!` before
  a command that must fail; `rules_text`).

  `permission_profile` is what the agent may do in the stage
  (`ClaudeControlPlaneProtocol.Job.permission_profiles/0`), with tool rules
  allowed and denied on top (`allowed_tools`, `denied_tools`, one per line in
  a form). `agent` names the agent the stage runs as: one of the repository's
  (`.claude/agents/`) or of the pipeline's `agents`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias ClaudeControlPlane.Pipelines.Prompt
  alias ClaudeControlPlaneProtocol.Job

  @type t :: %__MODULE__{
          key: String.t() | nil,
          name: String.t() | nil,
          prompt: String.t() | nil,
          max_attempts: pos_integer(),
          pause_after: boolean(),
          model: String.t() | nil,
          max_budget_usd: Decimal.t() | nil,
          timeout_minutes: pos_integer(),
          output_schema: map() | nil,
          output_schema_json: String.t() | nil,
          gates: [map()],
          gates_text: String.t() | nil,
          rules: [map()],
          rules_text: String.t() | nil,
          permission_profile: String.t(),
          agent: String.t() | nil,
          allowed_tools: [String.t()],
          allowed_tools_text: String.t() | nil,
          denied_tools: [String.t()],
          denied_tools_text: String.t() | nil
        }

  @models ~w(haiku sonnet opus)
  @key_format ~r/^[a-z0-9][a-z0-9_-]{0,39}$/

  @primary_key false
  embedded_schema do
    field :key, :string
    field :name, :string
    field :prompt, :string
    field :max_attempts, :integer, default: 2
    field :pause_after, :boolean, default: false
    field :model, :string
    field :max_budget_usd, :decimal
    field :timeout_minutes, :integer, default: 60
    field :output_schema, :map
    field :output_schema_json, :string, virtual: true
    field :gates, {:array, :map}, default: []
    field :gates_text, :string, virtual: true
    field :rules, {:array, :map}, default: []
    field :rules_text, :string, virtual: true
    field :permission_profile, :string, default: "total"
    field :agent, :string
    field :allowed_tools, {:array, :string}, default: []
    field :allowed_tools_text, :string, virtual: true
    field :denied_tools, {:array, :string}, default: []
    field :denied_tools_text, :string, virtual: true
  end

  @rule ~r/^([A-Za-z_][A-Za-z0-9_]*)\s*(==|!=)\s*(.+)$/

  @doc "The models a stage may pick; `nil` keeps the CLI's default."
  @spec models() :: [String.t()]
  def models, do: @models

  @doc """
  Changeset for a stage. A blank key is derived from the name; the extra
  output fields may come as JSON text (`output_schema_json`, from a form).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [
      :key,
      :name,
      :prompt,
      :max_attempts,
      :pause_after,
      :model,
      :max_budget_usd,
      :timeout_minutes,
      :output_schema,
      :output_schema_json,
      :gates_text,
      :rules_text,
      :permission_profile,
      :agent,
      :allowed_tools_text,
      :denied_tools_text
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name], message: "dê um nome à etapa")
    |> validate_required([:prompt], message: "escreva o prompt da etapa")
    |> validate_length(:name, max: 80)
    |> derive_key()
    |> validate_format(:key, @key_format, message: "use letras minúsculas, números, - ou _")
    |> validate_number(:max_attempts, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_number(:max_budget_usd, greater_than: 0)
    |> validate_required([:timeout_minutes], message: "informe o tempo máximo")
    |> validate_number(:timeout_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 1440,
      message: "use de 1 a 1440 minutos"
    )
    |> validate_inclusion(:model, @models)
    |> validate_prompt_variables()
    |> parse_output_schema()
    |> parse_gates()
    |> parse_rules()
    |> validate_inclusion(:permission_profile, Job.permission_profiles(),
      message: "escolha um perfil de permissão"
    )
    |> validate_length(:agent, max: 100)
    |> parse_tools(:allowed_tools)
    |> parse_tools(:denied_tools)
  end

  @doc "The tools a stage allows beyond its profile, one per line."
  @spec allowed_tools_text(t()) :: String.t()
  def allowed_tools_text(%__MODULE__{allowed_tools: tools}), do: Enum.join(tools, "\n")

  @doc "The tools a stage denies, one per line."
  @spec denied_tools_text(t()) :: String.t()
  def denied_tools_text(%__MODULE__{denied_tools: tools}), do: Enum.join(tools, "\n")

  defp parse_tools(changeset, field) do
    case lines(changeset, "#{field}_text") do
      {:ok, tools} when length(tools) <= 20 -> put_change(changeset, field, tools)
      {:ok, _tools} -> add_error(changeset, :"#{field}_text", "use no máximo 20 regras")
      :absent -> changeset
    end
  end

  @doc "A stage's gates as the form shows them: one per line, `!` when it must fail."
  @spec gates_text(t()) :: String.t()
  def gates_text(%__MODULE__{gates: gates}) do
    Enum.map_join(gates, "\n", fn
      %{"command" => command, "expect" => "fail"} -> "! " <> command
      %{"command" => command} -> command
    end)
  end

  @doc "A stage's rules as the form shows them: one per line."
  @spec rules_text(t()) :: String.t()
  def rules_text(%__MODULE__{rules: rules}),
    do: Enum.map_join(rules, "\n", &"#{&1["field"]} #{&1["op"]} #{&1["value"]}")

  defp lines(changeset, field) do
    case changeset.params do
      %{^field => text} ->
        {:ok,
         (text || "")
         |> String.split("\n")
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))}

      _no_text ->
        :absent
    end
  end

  defp parse_gates(changeset) do
    with {:ok, lines} <- lines(changeset, "gates_text") do
      gates =
        Enum.map(lines, fn
          "!" <> command -> %{"command" => String.trim(command), "expect" => "fail"}
          command -> %{"command" => command, "expect" => "pass"}
        end)

      unknown = gates |> Enum.flat_map(&Prompt.unknown_variables(&1["command"])) |> Enum.uniq()

      cond do
        length(gates) > 10 ->
          add_error(changeset, :gates_text, "use no máximo 10 gates")

        unknown != [] ->
          add_error(
            changeset,
            :gates_text,
            "variáveis desconhecidas: #{Enum.join(unknown, ", ")}"
          )

        true ->
          put_change(changeset, :gates, gates)
      end
    else
      :absent -> changeset
    end
  end

  defp parse_rules(changeset) do
    case lines(changeset, "rules_text") do
      {:ok, lines} ->
        put_rules(changeset, Enum.map(lines, &Regex.run(@rule, &1, capture: :all_but_first)))

      :absent ->
        changeset
    end
  end

  defp put_rules(changeset, rules) do
    if Enum.all?(rules, &is_list/1) do
      rules =
        Enum.map(rules, fn [field, op, value] ->
          %{"field" => field, "op" => op, "value" => String.trim(value)}
        end)

      put_change(changeset, :rules, rules)
    else
      add_error(
        changeset,
        :rules_text,
        "use uma regra por linha: campo == valor ou campo != valor"
      )
    end
  end

  defp derive_key(changeset) do
    case get_field(changeset, :key) do
      key when key in [nil, ""] -> put_change(changeset, :key, slug(get_field(changeset, :name)))
      _key -> changeset
    end
  end

  defp slug(nil), do: nil

  defp slug(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end

  defp validate_prompt_variables(changeset) do
    validate_change(changeset, :prompt, fn :prompt, prompt ->
      case Prompt.unknown_variables(prompt) do
        [] -> []
        unknown -> [prompt: "variáveis desconhecidas: #{Enum.join(unknown, ", ")}"]
      end
    end)
  end

  defp parse_output_schema(changeset) do
    case get_change(changeset, :output_schema_json) do
      nil -> changeset
      "" -> put_change(changeset, :output_schema, nil)
      json -> decode_schema(changeset, json)
    end
  end

  defp decode_schema(changeset, json) do
    case Jason.decode(json) do
      {:ok, %{"type" => "object", "properties" => properties} = schema}
      when is_map(properties) ->
        put_change(changeset, :output_schema, schema)

      {:ok, _other} ->
        add_error(
          changeset,
          :output_schema_json,
          ~s(precisa ser um objeto JSON Schema com "type": "object" e "properties")
        )

      {:error, _reason} ->
        add_error(changeset, :output_schema_json, "JSON inválido")
    end
  end
end
