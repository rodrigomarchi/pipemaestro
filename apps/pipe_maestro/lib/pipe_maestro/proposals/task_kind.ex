defmodule PipeMaestro.Proposals.TaskKind do
  @moduledoc """
  A task written by the agent from an idea or a GitHub issue
  (`PipeMaestro.Proposals`) for a project: it studies the project's
  directory and answers with the
  task's title, its prompt (context, the files involved, how to reproduce,
  acceptance criteria) and which of the workspace's pipelines fits, saying
  whether the request is clear enough to run on its own. The person opens the
  new-task form filled with it.

  The request may name the pipeline (`pipeline_id`): the agent writes for it,
  and the proposal uses it whatever the agent names back (its own suggestion
  only if the pipeline is gone since). With `auto_approve`, the task is
  created and started as the job ends, on behalf of who asked
  (`PipeMaestro.Proposals.job_finished/1`); a request without it (an older
  one, or a triage) waits for review.
  """
  @behaviour PipeMaestro.Proposals.Kind

  alias Ecto.Changeset
  alias PipeMaestro.Integrations.IssueUrl
  alias PipeMaestro.Pipelines
  alias PipeMaestro.Pipelines.Prompt
  alias PipeMaestro.Proposals
  alias PipeMaestro.Proposals.Instructions
  alias PipeMaestro.Tasks.Questionnaire
  alias PipeMaestro.Workspaces.Workspace

  @types %{
    project_id: :binary_id,
    runner_id: :binary_id,
    directory: :string,
    request: :string,
    issue_url: :string,
    feedback: :string,
    pipeline_id: :binary_id,
    auto_approve: :boolean,
    linked_repo_id: :binary_id,
    issue_number: :integer
  }

  # A round's feedback: a comment, or the answers to the agent's questions
  # (`PipeMaestro.Proposals.answer_questions/4`).
  @feedback_length 8_000

  @doc "How long a round's feedback may be."
  @spec feedback_length() :: pos_integer()
  def feedback_length, do: @feedback_length

  @impl true
  def name, do: "task"

  @impl true
  def label, do: "Tarefa"

  @impl true
  def icon, do: "hero-queue-list"

  @impl true
  def changeset(attrs, workspace) do
    {%{}, @types}
    |> Changeset.cast(attrs, Map.keys(@types) -- [:runner_id, :directory])
    |> Changeset.validate_required([:project_id], message: "escolha um projeto")
    |> Changeset.validate_required([:request], message: "conte a ideia da tarefa")
    |> Changeset.validate_length(:request, max: 16_000)
    |> Changeset.validate_length(:feedback, max: @feedback_length)
    |> Changeset.validate_format(:issue_url, IssueUrl.regex(), message: IssueUrl.message())
    |> validate_pipeline(workspace)
  end

  defp validate_pipeline(changeset, workspace) do
    case Changeset.get_change(changeset, :pipeline_id) do
      nil ->
        changeset

      id ->
        if Pipelines.get_pipeline(workspace.id, id),
          do: changeset,
          else: Changeset.add_error(changeset, :pipeline_id, "não é um pipeline deste workspace")
    end
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

      #{pipelines_section(workspace, input[:pipeline_id])}
      """,
      system_prompt: system_prompt(),
      output_schema: schema(),
      scratch: true,
      timeout_ms: 15 * 60 * 1000
    }
  end

  defp pipelines_section(workspace, nil),
    do: "## Os pipelines deste workspace\n\n" <> pipelines(workspace)

  defp pipelines_section(workspace, pipeline_id) do
    case Pipelines.get_pipeline(workspace.id, pipeline_id) do
      nil ->
        pipelines_section(workspace, nil)

      pipeline ->
        """
        ## O pipeline desta tarefa

        #{describe(pipeline)}

        A pessoa escolheu este pipeline: escreva a tarefa para as etapas dele e devolva o
        nome dele em `pipeline`.
        """
    end
  end

  defp describe(pipeline) do
    stages = Enum.map_join(pipeline.stages, " → ", & &1.name)
    "- **#{pipeline.name}**: #{pipeline.description || "sem descrição"} (#{stages})"
  end

  defp pipelines(workspace) do
    case Pipelines.list_pipelines(workspace) do
      [] ->
        "Nenhum ainda: deixe `pipeline` vazio."

      pipelines ->
        Enum.map_join(pipelines, "\n", &describe/1)
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
    - `pronta`: se a ideia está clara o bastante para rodar sozinha.

    ## Perguntas

    Só quando `pronta` é `false`: em `perguntas`, de 1 a 4 perguntas que uma pessoa precisa
    responder antes. Com `pronta: true`, omita `perguntas`.

    - cada pergunta é uma decisão que muda a tarefa e que o código não responde; não
      pergunte o que você pode descobrir lendo o projeto;
    - `titulo`: um rótulo curto do assunto (até 12 caracteres); `pergunta`: termina com "?";
      `multipla`: `true` quando mais de uma opção pode ser escolhida;
    - `opcoes`: de 2 a 4, cada uma com `rotulo` (até 5 palavras), `descricao` (o que essa
      escolha implica para a tarefa) e `preview` opcional (um exemplo em Markdown);
    - marque a opção que você recomenda com `recomendada: true` (uma só, a primeira);
    - "Outro", com texto livre, é sempre oferecido pela plataforma: não o ponha nas opções;
    - a ferramenta `AskUserQuestion` não existe aqui: toda pergunta vai em `perguntas`.

    A pessoa responde na plataforma, e as respostas voltam numa nova rodada para você
    reescrever a tarefa com elas.

    Responda no formato pedido, com `analise` (Markdown: o que você entendeu do pedido e do
    código). Escreva em português.
    """
  end

  @doc "The JSON Schema of the answer."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "$comment" => "pipemaestro-kind:task",
      "required" => ["analise", "titulo", "descricao", "pipeline", "pronta"],
      "properties" => %{
        "analise" => %{"type" => "string"},
        "titulo" => %{"type" => "string", "maxLength" => 120},
        "descricao" => %{"type" => "string"},
        "pipeline" => %{"type" => "string"},
        "pronta" => %{"type" => "boolean"},
        "perguntas" => Prompt.questions_schema()
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
      suggested = Proposals.text(output["pipeline"])
      pipeline = chosen_pipeline(job, input["pipeline_id"]) || find_pipeline(job, suggested)
      pipeline_name = if pipeline, do: pipeline.name, else: suggested
      {questions, legacy_questions} = questions(output["perguntas"])

      {:ok,
       %{
         analysis: Proposals.text(output["analise"]),
         title: String.slice(title, 0, 120),
         prompt: description,
         pipeline_name: pipeline_name,
         pipeline: pipeline,
         ready: output["pronta"] == true,
         auto_approve: input["auto_approve"] == true,
         questions: questions,
         legacy_questions: legacy_questions,
         task_params:
           %{
             "title" => String.slice(title, 0, 120),
             "prompt" => description,
             "pipeline_id" => pipeline && pipeline.id,
             "project_id" => input["project_id"]
           }
           |> put_issue(input["issue_url"])
       }}
    end
  end

  # The questionnaire of ADR 0029 when the agent asked in it; else the
  # phrases of an older answer, read as they are.
  defp questions(perguntas) do
    case Questionnaire.normalize(perguntas) do
      {:ok, questions} ->
        {questions, []}

      :error ->
        {[], perguntas |> List.wrap() |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))}
    end
  end

  defp put_issue(params, nil), do: params
  defp put_issue(params, url), do: Map.put(params, "issue_url", url)

  defp chosen_pipeline(_job, nil), do: nil

  defp chosen_pipeline(job, id), do: Pipelines.get_pipeline(job.workspace_id, id)

  defp find_pipeline(_job, ""), do: nil

  defp find_pipeline(job, name) do
    %Workspace{id: job.workspace_id}
    |> Pipelines.list_pipelines()
    |> Enum.find(&(String.downcase(&1.name) == String.downcase(name)))
  end
end
