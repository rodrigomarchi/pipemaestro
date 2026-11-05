defmodule PipeMaestro.Proposals.PipelineKind do
  @moduledoc """
  A pipeline for an existing project (`project_id`), proposed by the agent
  after studying the project's directory (`PipeMaestro.Proposals`). The
  person opens the pipeline form filled with the proposal. A project itself
  is proposed by `PipeMaestro.Proposals.ProjectKind`; an answer from before
  that still carries one is read without it.
  """
  @behaviour PipeMaestro.Proposals.Kind

  alias Ecto.Changeset
  alias PipeMaestro.Pipelines.{Stage, Yaml}
  alias PipeMaestro.Proposals
  alias PipeMaestro.Proposals.Instructions

  @types %{
    project_id: :binary_id,
    runner_id: :binary_id,
    directory: :string,
    request: :string,
    feedback: :string
  }

  @impl true
  def name, do: "pipeline"

  @impl true
  def label, do: "Pipeline"

  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def changeset(attrs, _workspace) do
    {%{}, @types}
    |> Changeset.cast(attrs, [:project_id, :request, :feedback])
    |> Changeset.validate_required([:project_id], message: "escolha um projeto")
    |> Changeset.validate_required([:request], message: "conte o que o pipeline deve fazer")
    |> Changeset.validate_length(:request, max: 8_000)
    |> Changeset.validate_length(:feedback, max: 4_000)
  end

  @impl true
  def job(input, _workspace, previous) do
    %{
      title: input.request,
      prompt: """
      Analise o projeto do diretório `#{input.directory}` e proponha um pipeline do
      PipeMaestro para o pedido abaixo.

      #{input.request}

      #{Instructions.revision(previous && previous.structured_output, input[:feedback])}
      """,
      system_prompt: system_prompt(),
      output_schema: schema(),
      scratch: true,
      timeout_ms: 20 * 60 * 1000
    }
  end

  defp system_prompt do
    """
    # Você está propondo um pipeline do PipeMaestro

    #{Instructions.study_project()}
    4. **Rode** os comandos de teste e de lint que vai propor e registre em `verificacoes`
       se passaram. Se um precisar de serviço externo (banco, docker), diga isso em
       `observacao` em vez de inventar.

    #{Instructions.pipeline_format()}

    ## Sua resposta

    Responda no formato pedido: `analise` (Markdown: o que o projeto é e como funciona),
    `verificacoes` e `pipeline`. Escreva em português.
    """
  end

  @doc "The JSON Schema of the answer."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "$comment" => "pipemaestro-kind:pipeline",
      "required" => ["analise", "verificacoes", "pipeline"],
      "properties" => %{
        "analise" => %{
          "type" => "string",
          "description" =>
            "Markdown: o que o projeto é, a stack, como instala, roda, testa, faz lint e entrega."
        },
        "verificacoes" => Proposals.checks_schema(),
        "pipeline" => pipeline_schema()
      }
    }
  end

  @doc "The schema of a pipeline in an answer, in the YAML's shape."
  @spec pipeline_schema() :: map()
  def pipeline_schema do
    %{
      "type" => "object",
      "required" => ["name", "stages"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "delivery" => %{"type" => "string", "enum" => ["none", "commit", "pr"]},
        "system_prompt" => %{"type" => "string"},
        "stages" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 20,
          "items" => %{
            "type" => "object",
            "required" => ["key", "name", "prompt"],
            "properties" => %{
              "key" => %{"type" => "string"},
              "name" => %{"type" => "string"},
              "prompt" => %{"type" => "string"},
              "max_attempts" => %{"type" => "integer", "minimum" => 1, "maximum" => 5},
              "model" => %{"type" => "string", "enum" => Stage.models()},
              "timeout_minutes" => %{"type" => "integer", "minimum" => 1, "maximum" => 1440},
              "gates" => %{"type" => "array", "items" => %{"type" => "string"}},
              "rules" => %{"type" => "array", "items" => %{"type" => "string"}},
              "group" => %{"type" => "string"}
            }
          }
        }
      }
    }
  end

  @impl true
  def result(output, _job) do
    case output["pipeline"] do
      %{"stages" => [_ | _]} = pipeline ->
        {:ok,
         %{
           analysis: Proposals.text(output["analise"]),
           checks: Proposals.checks(output["verificacoes"]),
           pipeline: pipeline |> Yaml.from_map() |> Yaml.without_caps()
         }}

      _incomplete ->
        {:error, "O agente não devolveu um pipeline com etapas."}
    end
  end
end
