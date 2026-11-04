defmodule PipeMaestro.Proposals.PipelineKind do
  @moduledoc """
  A pipeline and the project of a directory, proposed by the agent after
  studying it (`PipeMaestro.Proposals`). The person reviews the project, saves
  it, and opens the pipeline form filled with the proposal.
  """
  @behaviour PipeMaestro.Proposals.Kind

  alias Ecto.Changeset
  alias PipeMaestro.Pipelines.{Stage, Yaml}
  alias PipeMaestro.Proposals
  alias PipeMaestro.Proposals.Instructions

  @types %{runner_id: :binary_id, directory: :string, request: :string, feedback: :string}

  @impl true
  def name, do: "pipeline"

  @impl true
  def label, do: "Pipeline e projeto"

  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def changeset(attrs, _workspace) do
    {%{}, @types}
    |> Changeset.cast(attrs, Map.keys(@types))
    |> Changeset.validate_required([:runner_id], message: "escolha um runner online")
    |> Changeset.validate_required([:directory], message: "escolha o diretório do projeto")
    |> Changeset.validate_required([:request], message: "conte o que o pipeline deve fazer")
    |> Changeset.validate_length(:request, max: 8_000)
    |> Changeset.validate_length(:feedback, max: 4_000)
  end

  @impl true
  def job(input, _workspace, previous) do
    %{
      title: input.request,
      prompt: """
      Analise o projeto do diretório `#{input.directory}` e proponha a configuração do projeto
      e um pipeline do PipeMaestro para o pedido abaixo.

      #{input.request}

      #{Instructions.revision(previous && previous.structured_output, input[:feedback])}
      """,
      system_prompt: system_prompt(),
      output_schema: schema(),
      scratch: true,
      max_budget_usd: 3,
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
    `verificacoes`, `projeto` e `pipeline`. Escreva em português.
    """
  end

  @doc "The JSON Schema of the answer."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "$comment" => "pipemaestro-kind:pipeline",
      "required" => ["analise", "verificacoes", "projeto", "pipeline"],
      "properties" => %{
        "analise" => %{
          "type" => "string",
          "description" =>
            "Markdown: o que o projeto é, a stack, como instala, roda, testa, faz lint e entrega."
        },
        "verificacoes" => %{
          "type" => "array",
          "description" => "Cada comando que você rodou para conferir o que propõe.",
          "items" => %{
            "type" => "object",
            "required" => ["comando", "passou"],
            "properties" => %{
              "comando" => %{"type" => "string"},
              "passou" => %{"type" => "boolean"},
              "observacao" => %{"type" => "string"}
            }
          }
        },
        "projeto" => project_schema(),
        "pipeline" => pipeline_schema()
      }
    }
  end

  @doc "The schema of a project's configuration in an answer."
  @spec project_schema() :: map()
  def project_schema do
    %{
      "type" => "object",
      "required" => ["nome"],
      "properties" => %{
        "nome" => %{"type" => "string"},
        "setup" => %{"type" => "string", "description" => "Comando que prepara um checkout novo."},
        "teste" => %{"type" => "string", "description" => "Comando que roda os testes."},
        "lint" => %{"type" => "string", "description" => "Comando de lint/formatação/tipos."},
        "copy_paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Pastas de dependências e build a copiar para cada worktree."
        },
        "notas" => %{
          "type" => "string",
          "description" => "Markdown com o que o agente de cada etapa precisa saber do projeto."
        }
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
        "max_task_cost_usd" => %{"type" => "number"},
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
  def result(output, job) do
    with %{} = project <- output["projeto"],
         %{"stages" => [_ | _]} = pipeline <- output["pipeline"] do
      {:ok,
       %{
         analysis: Proposals.text(output["analise"]),
         checks: checks(output["verificacoes"]),
         project: project_attrs(project, Proposals.input(job)["directory"]),
         pipeline: Yaml.from_map(pipeline)
       }}
    else
      _incomplete -> {:error, "O agente não devolveu um projeto e um pipeline com etapas."}
    end
  end

  @doc "A project in an answer as the project form's attributes, for `directory`."
  @spec project_attrs(map(), String.t()) :: map()
  def project_attrs(project, directory) do
    %{
      "name" => Proposals.text(project["nome"]),
      "directory" => directory,
      "setup_command" => Proposals.text(project["setup"]),
      "test_command" => Proposals.text(project["teste"]),
      "lint_command" => Proposals.text(project["lint"]),
      "copy_paths_text" => project["copy_paths"] |> List.wrap() |> Enum.join("\n"),
      "notes" => Proposals.text(project["notas"])
    }
  end

  defp checks(list) when is_list(list) do
    for %{"comando" => command} = check <- list, is_binary(command) do
      %{
        command: command,
        passed: check["passou"] == true,
        note: Proposals.text(check["observacao"])
      }
    end
  end

  defp checks(_other), do: []
end
