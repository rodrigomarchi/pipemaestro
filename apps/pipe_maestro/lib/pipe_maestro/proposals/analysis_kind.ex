defmodule PipeMaestro.Proposals.AnalysisKind do
  @moduledoc """
  The analysis of a failure, asked by the platform itself when a task pauses
  because a stage failed or blocked with nothing to ask
  (`PipeMaestro.Tasks.request_analysis/1`). The agent reads what the control
  plane kept of the task — the same context as a suggested decision
  (`PipeMaestro.Proposals.DecisionKind.context/1`) — and, when the runner
  can, the code in a disposable worktree. It answers with a diagnosis and the
  questions (`perguntas`, `PipeMaestro.Pipelines.Prompt.questions_schema/0`)
  whose answers would fix the failure; they become the task's questionnaire.

  It runs with no one asking, so its time limit is shorter than a suggested
  decision's, and like every proposal it has no cost cap. It is good only for the pause it was asked about
  (`current?/2`).
  """
  @behaviour PipeMaestro.Proposals.Kind

  alias Ecto.Changeset
  alias PipeMaestro.Pipelines.Prompt
  alias PipeMaestro.Proposals
  alias PipeMaestro.Proposals.{DecisionKind, Instructions}
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks
  alias PipeMaestro.Tasks.{Questionnaire, Task}

  @types %{
    task_id: :binary_id,
    runner_id: :binary_id,
    directory: :string,
    stage: :integer,
    decisions: :integer,
    feedback: :string
  }

  @timeout_ms 10 * 60 * 1000

  @impl true
  def name, do: "analysis"

  @impl true
  def label, do: "Análise de falha"

  @impl true
  def icon, do: "hero-magnifying-glass"

  @impl true
  def changeset(attrs, workspace) do
    changeset =
      {%{}, @types}
      |> Changeset.cast(attrs, [:task_id, :feedback])
      |> Changeset.validate_required([:task_id])

    with task_id when is_binary(task_id) <- Changeset.get_field(changeset, :task_id),
         %Task{} = task <- find_task(workspace, task_id) do
      changeset
      |> Changeset.put_change(:runner_id, task.runner_id)
      |> Changeset.put_change(:directory, directory(task))
      # The pause this analysis is for: it is dropped once the pause is over.
      |> Changeset.put_change(:stage, task.current_stage)
      |> Changeset.put_change(:decisions, length(Tasks.list_decisions(task)))
      |> validate_paused(task)
    else
      _missing -> Changeset.add_error(changeset, :task_id, "não é uma tarefa deste workspace")
    end
  end

  # The code is read only in a disposable worktree: a runner that cannot run
  # one gets the context alone.
  defp directory(%Task{git: true, runner: %Runner{} = runner} = task) do
    if Proposals.capable?(runner), do: task.directory
  end

  defp directory(_task), do: nil

  defp validate_paused(changeset, %Task{status: :awaiting_decision}), do: changeset

  defp validate_paused(changeset, _task),
    do: Changeset.add_error(changeset, :task_id, "a tarefa não está esperando uma decisão")

  defp find_task(workspace, task_id) do
    Tasks.get_task!(workspace, task_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  @doc """
  Whether `task` still waits for the decision the analysis was asked about
  (its `input`): the same stage, with no decision taken since.
  """
  @spec current?(map(), Task.t()) :: boolean()
  def current?(input, %Task{} = task), do: DecisionKind.current?(input, task)

  @impl true
  def job(input, workspace, previous) do
    task = Tasks.get_task!(workspace, input.task_id)

    %{
      title: "Análise: #{task.title}",
      prompt: """
      A tarefa abaixo parou porque uma etapa falhou ou ficou bloqueada sem dizer o que perguntar.
      Diagnostique a falha e pergunte à pessoa o que é preciso para corrigi-la.

      #{Instructions.revision(previous && previous.structured_output, input[:feedback])}

      #{DecisionKind.context(task)}
      """,
      system_prompt: system_prompt(),
      output_schema: schema(),
      scratch: input[:directory] != nil,
      timeout_ms: @timeout_ms
    }
  end

  defp system_prompt do
    """
    # Você está analisando a falha de uma tarefa do PipeMaestro

    Um pipeline de agentes executava a tarefa etapa por etapa e parou: as tentativas de uma
    etapa acabaram, um gate não passou, o CLI falhou, ou o agente bloqueou sem dizer o que
    perguntar. Você recebe o que aconteceu (o pedido, as tentativas com erros, gates,
    artefatos e diffs) e, quando houver, pode ler o código-base num worktree descartável.

    Responda com:

    - `diagnostico`: em Markdown, o que falhou e por quê. Seja concreto: cite o erro, o
      arquivo ou o gate.
    - `perguntas`: de 1 a 4 perguntas para a pessoa, cada uma uma decisão que muda o rumo.

    Ao perguntar:

    - pergunte só o que muda a solução e você não descobre sozinho no código;
    - uma decisão por pergunta, terminando com "?";
    - de 2 a 4 opções que de fato resolvem a falha, cada uma com uma descrição do que implica;
    - a opção que você recomenda vem primeiro, com `recomendada: true`;
    - use `preview` para mostrar um trecho de código ou diff quando ajudar a escolher.

    A resposta da pessoa vai para o agente da próxima tentativa. Responda no formato pedido,
    em português.
    """
  end

  @doc "The JSON Schema of the answer."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "$comment" => "pipemaestro-kind:analysis",
      "required" => ["diagnostico", "perguntas"],
      "properties" => %{
        "diagnostico" => %{
          "type" => "string",
          "description" => "Markdown: o que falhou e por quê."
        },
        "perguntas" => Prompt.questions_schema()
      }
    }
  end

  @impl true
  def result(output, job) do
    case Questionnaire.normalize(output["perguntas"]) do
      {:ok, questions} ->
        {:ok,
         %{
           task_id: Proposals.input(job)["task_id"],
           diagnosis: Proposals.text(output["diagnostico"]),
           questions: questions
         }}

      :error ->
        {:error, "O agente não fez perguntas válidas (de 1 a 4, cada uma com 2 a 4 opções)."}
    end
  end
end
