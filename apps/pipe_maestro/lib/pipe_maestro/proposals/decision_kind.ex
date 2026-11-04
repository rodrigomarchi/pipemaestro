defmodule PipeMaestro.Proposals.DecisionKind do
  @moduledoc """
  The decision a paused task waits for, suggested by the agent
  (`PipeMaestro.Proposals`): a stage blocked, a rule that matched, attempts
  exhausted or the budget reached. The agent reads what the control plane
  kept of the task — the question, the options, each attempt's summary,
  error, gates and diff — and, in a disposable worktree of the task's
  directory, the code it started from. It answers with a diagnosis, the action
  it recommends (retry, advance or cancel) and the instructions for it, which
  the person reviews and applies.

  The task's own worktree is not read: its stages' changes are usually not
  committed, so the diff goes in the prompt instead.
  """
  @behaviour PipeMaestro.Proposals.Kind

  alias Ecto.Changeset
  alias PipeMaestro.Proposals
  alias PipeMaestro.Proposals.Instructions
  alias PipeMaestro.Tasks
  alias PipeMaestro.Tasks.{Engine, Task}

  @types %{task_id: :binary_id, runner_id: :binary_id, directory: :string, feedback: :string}
  @actions ~w(retry advance cancel)
  # The latest attempts of the step the agent reads, newest last.
  @attempts 2

  @impl true
  def name, do: "decision"

  @impl true
  def label, do: "Decisão"

  @impl true
  def icon, do: "hero-hand-raised"

  @impl true
  def changeset(attrs, workspace) do
    changeset =
      {%{}, @types}
      |> Changeset.cast(attrs, [:task_id, :feedback])
      |> Changeset.validate_required([:task_id])
      |> Changeset.validate_length(:feedback, max: 4_000)

    with task_id when is_binary(task_id) <- Changeset.get_field(changeset, :task_id),
         %Task{} = task <- find_task(workspace, task_id) do
      changeset
      |> Changeset.put_change(:runner_id, task.runner_id)
      |> Changeset.put_change(:directory, if(task.git, do: task.directory))
      |> validate_paused(task)
    else
      _missing -> Changeset.add_error(changeset, :task_id, "não é uma tarefa deste workspace")
    end
  end

  defp validate_paused(changeset, %Task{status: :awaiting_decision}), do: changeset

  defp validate_paused(changeset, _task),
    do: Changeset.add_error(changeset, :task_id, "a tarefa não está esperando uma decisão")

  defp find_task(workspace, task_id) do
    Tasks.get_task!(workspace, task_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  @impl true
  def job(input, workspace, previous) do
    task = Tasks.get_task!(workspace, input.task_id)

    %{
      title: task.title,
      prompt: """
      A tarefa abaixo parou e espera uma decisão. Diagnostique por quê e recomende o que fazer.

      #{context(task)}

      #{Instructions.revision(previous && previous.structured_output, input[:feedback])}
      """,
      system_prompt: system_prompt(),
      output_schema: schema(),
      scratch: input[:directory] != nil,
      max_budget_usd: 2,
      timeout_ms: 15 * 60 * 1000
    }
  end

  @doc "What the agent reads about `task`: the request, the question and the latest attempts."
  @spec context(Task.t()) :: String.t()
  def context(%Task{} = task) do
    step = Tasks.step_indexes(task, task.current_stage)

    runs =
      task.stage_runs
      |> Enum.filter(&(&1.index in step))
      |> Enum.sort_by(&{&1.attempt, &1.index})
      |> Enum.take(-@attempts)

    options = Tasks.options(task)

    """
    ## A tarefa: #{task.title}

    Pipeline **#{task.pipeline_name}**, diretório `#{task.directory}`.

    #{Instructions.cut(task.prompt, 4_000)}

    ## Por que ela parou

    #{task.decision_reason}
    #{if options != [], do: "\nOpções que o agente da etapa propôs:\n" <> Enum.map_join(options, "\n", &"- #{&1}")}

    ## As últimas tentativas

    #{Enum.map_join(runs, "\n", &attempt/1)}

    ## Decisões já tomadas nesta tarefa

    #{decisions(task)}
    """
  end

  defp attempt(run) do
    job = run.job || %{gates: nil, changes: nil}
    patch = get_in(job.changes || %{}, ["patch"])

    """
    ### Etapa "#{run.name}", tentativa #{run.attempt} (#{run.status})

    #{if run.instructions, do: "Instruções que ela recebeu:\n#{Instructions.cut(run.instructions, 1_000)}\n"}
    #{Instructions.cut(Engine.feedback(run.error, run.summary, job.gates), 3_000)}

    #{if run.artifact, do: "Artefato:\n\n#{Instructions.cut(run.artifact, 2_000)}\n"}
    #{if patch, do: "Diff da etapa:\n\n```diff\n#{Instructions.cut(patch, 4_000)}\n```\n"}
    """
  end

  defp decisions(task) do
    case Tasks.list_decisions(task) do
      [] ->
        "Nenhuma."

      decisions ->
        Enum.map_join(decisions, "\n", &decision_line/1)
    end
  end

  defp decision_line(decision) do
    instructions =
      if decision.instructions, do: ": #{Instructions.cut(decision.instructions, 500)}", else: ""

    "- #{decision.question} → #{decision.action}#{instructions}"
  end

  defp system_prompt do
    """
    # Você está ajudando a decidir uma tarefa parada do PipeMaestro

    Um pipeline de agentes executava a tarefa etapa por etapa e parou: uma etapa ficou
    bloqueada, uma regra pediu uma pessoa, as tentativas acabaram ou o orçamento estourou.
    Você recebe o que aconteceu (o pedido, a pergunta, as tentativas com erros, gates,
    artefatos e diffs) e pode ler o código-base num **worktree descartável** (sem as mudanças
    da tarefa, que estão no diff).

    Decida entre:

    - `retry`: rodar a etapa de novo, com instruções que corrijam o rumo;
    - `advance`: seguir para a próxima etapa (o que a etapa fez basta);
    - `cancel`: a tarefa não deve seguir (pedido errado, impossível, perigoso).

    Seja concreto: cite o erro, o arquivo ou o gate. As `instrucoes` vão direto para o
    agente da próxima tentativa; escreva-as para ele, no imperativo. Se o agente da etapa
    propôs opções, `escolha` é a que você recomenda (o texto exato), ou vazio.

    Responda no formato pedido, em português.
    """
  end

  @doc "The JSON Schema of the answer."
  @spec schema() :: map()
  def schema do
    alternative = %{
      "type" => "object",
      "required" => ["acao", "motivo"],
      "properties" => %{
        "acao" => %{"type" => "string", "enum" => @actions},
        "instrucoes" => %{"type" => "string"},
        "motivo" => %{"type" => "string"}
      }
    }

    %{
      "type" => "object",
      "x-pipemaestro-kind" => "decision",
      "required" => ["diagnostico", "acao", "instrucoes"],
      "properties" => %{
        "diagnostico" => %{
          "type" => "string",
          "description" => "Markdown: o que aconteceu e por quê."
        },
        "acao" => %{"type" => "string", "enum" => @actions},
        "escolha" => %{"type" => "string"},
        "instrucoes" => %{"type" => "string"},
        "alternativas" => %{"type" => "array", "items" => alternative}
      }
    }
  end

  @impl true
  def result(output, job) do
    action = output["acao"]

    if action in @actions do
      {:ok,
       %{
         task_id: Proposals.input(job)["task_id"],
         diagnosis: Proposals.text(output["diagnostico"]),
         action: action,
         choice: blank_to_nil(output["escolha"]),
         instructions: Proposals.text(output["instrucoes"]),
         alternatives:
           for %{"acao" => alt_action} = alt <- List.wrap(output["alternativas"]),
               alt_action in @actions do
             %{
               action: alt_action,
               instructions: Proposals.text(alt["instrucoes"]),
               reason: Proposals.text(alt["motivo"])
             }
           end
       }}
    else
      {:error, "O agente não recomendou uma ação (tentar de novo, avançar ou cancelar)."}
    end
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil
end
