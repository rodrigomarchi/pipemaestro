defmodule ClaudeControlPlane.Pipelines.Prompt do
  @moduledoc """
  What a stage's run is given: the prompt, built from the stage's template and
  the pipeline's fixed contract, and the output schema it must answer with.

  Every stage writes a Markdown artifact under `.control-plane/<task>/` in the
  task's working directory and answers with at least `status` (`"ok"`, or
  `"bloqueado"` when it needs a person) and `resumo`. Later stages read the
  earlier artifacts from disk; nothing else carries over between stages.
  """

  alias ClaudeControlPlane.Pipelines.Stage

  @variables ~w(tarefa.titulo tarefa.descricao tarefa.diretorio artefatos
                projeto.nome projeto.setup projeto.teste projeto.lint projeto.notas)

  # Each `projeto.*` variable and the project snapshot field it reads.
  @project_variables %{
    "projeto.nome" => "name",
    "projeto.setup" => "setup_command",
    "projeto.teste" => "test_command",
    "projeto.lint" => "lint_command",
    "projeto.notas" => "notes"
  }
  @variable ~r/\{\{\s*([^}\s]+)\s*\}\}/

  @base_schema %{
    "type" => "object",
    "properties" => %{
      "status" => %{
        "type" => "string",
        "enum" => ["ok", "bloqueado"],
        "description" =>
          "ok quando a etapa foi concluída; bloqueado quando precisa de uma decisão humana"
      },
      "resumo" => %{
        "type" => "string",
        "description" => "o que foi feito, ou por que está bloqueado, em poucas frases"
      }
    },
    "required" => ["status", "resumo"]
  }

  @typedoc "What a prompt is rendered with."
  @type context :: %{
          required(:task_id) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t(),
          required(:directory) => String.t(),
          required(:stage_index) => non_neg_integer(),
          optional(:project) => map() | nil,
          optional(:feedback) => String.t() | nil,
          required(:previous) => [Stage.t()],
          optional(:instructions) => String.t() | nil
        }

  @doc "The variables a stage's template may use, as `{{name}}`."
  @spec variables() :: [String.t()]
  def variables, do: @variables

  @doc "The variables of `template` that do not exist."
  @spec unknown_variables(String.t()) :: [String.t()]
  def unknown_variables(template) do
    @variable
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @variables))
  end

  @doc "Where the stage at `index` writes its artifact, relative to the working directory."
  @spec artifact_path(String.t(), non_neg_integer(), String.t()) :: String.t()
  def artifact_path(task_id, index, key) do
    number = (index + 1) |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join([".control-plane", task_id, "#{number}-#{key}.md"])
  end

  @doc "The output schema of a stage: its own fields plus `status` and `resumo`."
  @spec output_schema(Stage.t()) :: map()
  def output_schema(%Stage{output_schema: nil}), do: @base_schema

  def output_schema(%Stage{output_schema: extra}) do
    %{
      "type" => "object",
      "properties" => Map.merge(extra["properties"] || %{}, @base_schema["properties"]),
      "required" => Enum.uniq(@base_schema["required"] ++ (extra["required"] || []))
    }
  end

  @doc "The full prompt for a stage's run."
  @spec build(Stage.t(), context()) :: String.t()
  def build(%Stage{} = stage, context) do
    artifact = artifact_path(context.task_id, context.stage_index, stage.key)

    previous =
      context.previous
      |> Enum.with_index()
      |> Enum.map(fn {prev, index} ->
        "- #{prev.name}: #{artifact_path(context.task_id, index, prev.key)}"
      end)

    artifacts =
      if previous == [], do: "(nenhum: esta é a primeira etapa)", else: Enum.join(previous, "\n")

    [
      header(stage, context, artifact, artifacts),
      render(stage.prompt, context, artifacts),
      feedback(context[:feedback]),
      instructions(context[:instructions])
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp header(stage, context, artifact, artifacts) do
    """
    Você está executando a etapa "#{stage.name}" (#{context.stage_index + 1}) de um pipeline automatizado para a tarefa "#{context.title}".
    Regras desta execução:
    - Você começa sem contexto de etapas anteriores: o que elas produziram está nos artefatos abaixo; leia-os antes de agir.
    - Ninguém vai responder perguntas durante a execução. Se precisar de uma decisão humana, termine com status "bloqueado" e explique no resumo.
    - Escreva o resultado desta etapa em Markdown no arquivo #{artifact} (crie os diretórios se preciso).
    - Responda no formato estruturado pedido: status "ok" ao concluir, com um resumo curto.

    Artefatos das etapas anteriores:
    #{artifacts}
    """
    |> String.trim_trailing()
  end

  defp render(template, context, artifacts) do
    Regex.replace(@variable, template, fn whole, name ->
      case name do
        "tarefa.titulo" -> context.title
        "tarefa.descricao" -> context.description
        "tarefa.diretorio" -> context.directory
        "artefatos" -> artifacts
        "projeto." <> _field -> project_value(context[:project], name)
        _unknown -> whole
      end
    end)
  end

  # Without a project (or the setting), a `projeto.*` variable is blank.
  defp project_value(nil, _name), do: ""
  defp project_value(project, name), do: project[@project_variables[name]] || ""

  @doc """
  A gate command with its `{{projeto.*}}` variables filled in (the others
  make no sense for a command and are left as they are).
  """
  @spec render_command(String.t(), %{project: map() | nil}) :: String.t()
  def render_command(command, context) do
    Regex.replace(@variable, command, fn whole, name ->
      case name do
        "projeto." <> _field -> project_value(context[:project], name)
        _other -> whole
      end
    end)
  end

  defp feedback(nil), do: ""

  defp feedback(text),
    do: "A tentativa anterior desta etapa não passou. Corrija o que levou a isso:\n#{text}"

  defp instructions(nil), do: ""
  defp instructions(""), do: ""

  defp instructions(text),
    do: "Instruções adicionais de quem acompanha a tarefa (têm prioridade):\n#{text}"
end
