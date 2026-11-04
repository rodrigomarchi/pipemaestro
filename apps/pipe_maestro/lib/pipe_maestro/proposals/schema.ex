defmodule PipeMaestro.Proposals.Schema do
  @moduledoc """
  The JSON Schema a proposal's agent answers with (`--json-schema`): what it
  understood of the project, the commands it ran to check, the project's
  configuration and the pipeline, in the YAML's shape
  (`PipeMaestro.Pipelines.Yaml`).
  """

  alias PipeMaestro.Pipelines.Stage

  @doc "The schema."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
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
        "projeto" => project(),
        "pipeline" => pipeline()
      }
    }
  end

  defp project do
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

  defp pipeline do
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
          "items" => stage()
        }
      }
    }
  end

  defp stage do
    %{
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
  end
end
