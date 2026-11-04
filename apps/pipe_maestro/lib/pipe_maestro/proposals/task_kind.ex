defmodule PipeMaestro.Proposals.TaskKind do
  @moduledoc """
  A task written by the agent from an idea or a GitHub issue
  (`PipeMaestro.Proposals`): it studies the directory and answers with the
  task's title, its prompt (context, the files involved, how to reproduce,
  acceptance criteria) and which of the workspace's pipelines fits, saying
  whether the request is clear enough to run on its own. The person opens the
  new-task form filled with it.
  """
  @behaviour PipeMaestro.Proposals.Kind

  alias Ecto.Changeset
  alias PipeMaestro.Pipelines
  alias PipeMaestro.Proposals
  alias PipeMaestro.Proposals.Instructions
  alias PipeMaestro.Workspaces.Workspace

  @types %{
    runner_id: :binary_id,
    directory: :string,
    request: :string,
    issue_url: :string,
    feedback: :string
  }

  @impl true
  def name, do: "task"

  @impl true
  def label, do: "Tarefa"

  @impl true
  def icon, do: "hero-queue-list"

  @impl true
  def changeset(attrs, _workspace) do
    {%{}, @types}
    |> Changeset.cast(attrs, Map.keys(@types))
    |> Changeset.validate_required([:runner_id], message: "escolha um runner online")
    |> Changeset.validate_required([:directory], message: "escolha o diretório do projeto")
    |> Changeset.validate_required([:request], message: "conte a ideia da tarefa")
    |> Changeset.validate_length(:request, max: 16_000)
    |> Changeset.validate_length(:feedback, max: 4_000)
    |> Changeset.validate_format(:issue_url, ~r{^https://github\.com/[^/]+/[^/]+/issues/\d+$},
      message: "use o link de uma issue do GitHub"
    )
  end

  @impl true
  def job(input, workspace, previous) do
    issue = if input[:issue_url], do: "\nA ideia vem da issue #{input.issue_url}.\n", else: ""

    %{
      title:
        input.request |> String.split("\n", trim: true) |> List.first("") |> String.slice(0, 120),
      prompt: """
      Escreva uma tarefa do PipeMaestro para o projeto do diretório `#{input.directory}`, a
      partir da ideia abaixo.
      #{issue}
      #{input.request}

      #{Instructions.revision(previous && previous.structured_output, input[:feedback])}

      ## Os pipelines deste workspace

      #{pipelines(workspace)}
      """,
      system_prompt: system_prompt(),
      output_schema: schema(),
      scratch: true,
      max_budget_usd: 2,
      timeout_ms: 15 * 60 * 1000
    }
  end

  defp pipelines(workspace) do
    case Pipelines.list_pipelines(workspace) do
      [] ->
        "Nenhum ainda: deixe `pipeline` vazio."

      pipelines ->
        Enum.map_join(pipelines, "\n", fn pipeline ->
          stages = Enum.map_join(pipeline.stages, " → ", & &1.name)
          "- **#{pipeline.name}**: #{pipeline.description || "sem descrição"} (#{stages})"
        end)
    end
  end

  defp system_prompt do
    """
    # Você está escrevendo uma tarefa do PipeMaestro

    Uma tarefa é o pedido que um pipeline de agentes vai executar, etapa por etapa, até
    entregar um pull request. O agente de cada etapa lê o título e a descrição que você
    escrever, e só isso: ele não vê a conversa que originou a ideia.

    #{Instructions.study_project()}

    ## A tarefa

    - `titulo`: curto e específico (até 120 caracteres), no imperativo;
    - `descricao`: em Markdown, o prompt da tarefa:
      - o problema ou objetivo, com o contexto que você encontrou no código;
      - os arquivos e módulos envolvidos;
      - como reproduzir (num bug) ou como deve se comportar (numa funcionalidade);
      - os critérios de aceite, verificáveis;
      - o que está fora do escopo;
    - `pipeline`: o nome exato de um dos pipelines do workspace que melhor serve, ou vazio;
    - `pronta`: se a ideia está clara o bastante para rodar sozinha; se não estiver, liste
      em `perguntas` o que uma pessoa precisa responder antes.

    Responda no formato pedido, com `analise` (Markdown: o que você entendeu do pedido e do
    código). Escreva em português.
    """
  end

  @doc "The JSON Schema of the answer."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "x-pipemaestro-kind" => "task",
      "required" => ["analise", "titulo", "descricao", "pipeline", "pronta"],
      "properties" => %{
        "analise" => %{"type" => "string"},
        "titulo" => %{"type" => "string", "maxLength" => 120},
        "descricao" => %{"type" => "string"},
        "pipeline" => %{"type" => "string"},
        "pronta" => %{"type" => "boolean"},
        "perguntas" => %{"type" => "array", "items" => %{"type" => "string"}}
      }
    }
  end

  @impl true
  def result(output, job) do
    title = Proposals.text(output["titulo"])
    description = Proposals.text(output["descricao"])

    if title == "" or description == "" do
      {:error, "O agente não devolveu o título e a descrição da tarefa."}
    else
      input = Proposals.input(job)
      pipeline_name = Proposals.text(output["pipeline"])
      pipeline = find_pipeline(job, pipeline_name)

      {:ok,
       %{
         analysis: Proposals.text(output["analise"]),
         title: String.slice(title, 0, 120),
         prompt: description,
         pipeline_name: pipeline_name,
         pipeline: pipeline,
         ready: output["pronta"] == true,
         questions: output["perguntas"] |> List.wrap() |> Enum.filter(&is_binary/1),
         task_params: %{
           "title" => String.slice(title, 0, 120),
           "prompt" => description,
           "pipeline_id" => pipeline && pipeline.id,
           "runner_id" => job.runner_id,
           "directory" => input["directory"],
           "issue_url" => input["issue_url"]
         }
       }}
    end
  end

  defp find_pipeline(_job, ""), do: nil

  defp find_pipeline(job, name) do
    %Workspace{id: job.workspace_id}
    |> Pipelines.list_pipelines()
    |> Enum.find(&(String.downcase(&1.name) == String.downcase(name)))
  end
end
