defmodule PipeMaestro.Proposals.ProjectKind do
  @moduledoc """
  A project proposed by the agent after studying a directory of a runner
  (`PipeMaestro.Proposals`), before the project exists: its name, the
  commands that set up, test and lint it, the paths to clone into each
  worktree and notes for the agents. The person reviews it in the project
  form, filled with the answer and the runner and directory asked, and
  nothing is saved until they save it.
  """
  @behaviour PipeMaestro.Proposals.Kind

  alias Ecto.Changeset
  alias PipeMaestro.Proposals
  alias PipeMaestro.Proposals.Instructions

  @types %{
    runner_id: :binary_id,
    directory: :string,
    project_id: :binary_id,
    request: :string,
    feedback: :string
  }

  @impl true
  def name, do: "project"

  @impl true
  def label, do: "Projeto"

  @impl true
  def icon, do: "hero-folder"

  @impl true
  def changeset(attrs, _workspace) do
    {%{}, @types}
    |> Changeset.cast(attrs, [:runner_id, :directory, :request, :feedback])
    |> Changeset.validate_required([:runner_id], message: "escolha o runner do projeto")
    |> Changeset.validate_required([:directory], message: "escolha o diretório do projeto")
    |> Changeset.validate_length(:request, max: 8_000)
    |> Changeset.validate_length(:feedback, max: 4_000)
  end

  @impl true
  def job(input, _workspace, previous) do
    %{
      title: "Projeto do diretório #{input.directory}",
      prompt: """
      Analise o projeto do diretório `#{input.directory}` e proponha a configuração dele no
      PipeMaestro.
      #{if input[:request], do: "\nO que a pessoa pediu:\n\n#{input.request}\n"}
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
    # Você está configurando um projeto do PipeMaestro

    Um projeto é uma pasta de código num runner. Cada tarefa roda num worktree novo dela,
    preparado pelo comando de setup e com as pastas de dependências copiadas; os agentes
    rodam os comandos de teste e de lint e leem as notas do projeto.

    #{Instructions.study_project()}
    4. **Rode** os comandos de teste e de lint que vai propor e registre em `verificacoes`
       se passaram. Se um precisar de serviço externo (banco, docker), diga isso em
       `observacao` em vez de inventar.

    ## Sua resposta

    Responda no formato pedido: `analise` (Markdown: o que o projeto é e como funciona),
    `verificacoes` e `projeto`. Escreva em português.
    """
  end

  @doc "The JSON Schema of the answer."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "$comment" => "pipemaestro-kind:project",
      "required" => ["analise", "verificacoes", "projeto"],
      "properties" => %{
        "analise" => %{
          "type" => "string",
          "description" =>
            "Markdown: o que o projeto é, a stack, como instala, roda, testa, faz lint e entrega."
        },
        "verificacoes" => Proposals.checks_schema(),
        "projeto" => project_schema()
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

  @impl true
  def result(output, job) do
    case output["projeto"] do
      %{} = project ->
        {:ok,
         %{
           analysis: Proposals.text(output["analise"]),
           checks: Proposals.checks(output["verificacoes"]),
           project: project_attrs(project, job.runner_id, Proposals.input(job)["directory"])
         }}

      _missing ->
        {:error, "O agente não devolveu a configuração do projeto."}
    end
  end

  @doc "A project in an answer as the project form's attributes, for a runner's directory."
  @spec project_attrs(map(), Ecto.UUID.t() | nil, String.t() | nil) :: map()
  def project_attrs(project, runner_id, directory) do
    %{
      "name" => Proposals.text(project["nome"]),
      "runner_id" => runner_id,
      "directory" => directory,
      "setup_command" => Proposals.text(project["setup"]),
      "test_command" => Proposals.text(project["teste"]),
      "lint_command" => Proposals.text(project["lint"]),
      "copy_paths_text" =>
        project["copy_paths"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join("\n"),
      "notes" => Proposals.text(project["notas"])
    }
  end
end
