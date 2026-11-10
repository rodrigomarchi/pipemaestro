defmodule PipeMaestro.Proposals.ImproveKind do
  @moduledoc """
  Improvements to a pipeline and to its project's notes, proposed by the
  agent from how the pipeline has worked (`PipeMaestro.Proposals`). It reads
  the latest finished tasks (`PipeMaestro.Tasks.history/2`): where stages
  failed, which gates did not pass, where tasks stopped for a person and what
  was decided, and what each stage cost; and it studies the code of the
  project's directory (`project_id`).
  It answers with the revised pipeline and notes, and the changes it made and
  why. The person saves the notes and opens the pipeline form filled with the
  revision, which saves as the pipeline's next version.
  """
  @behaviour PipeMaestro.Proposals.Kind

  alias Ecto.Changeset
  alias PipeMaestro.{Pipelines, Projects, Tasks, Usage}
  alias PipeMaestro.Pipelines.{Pipeline, Yaml}
  alias PipeMaestro.Proposals
  alias PipeMaestro.Proposals.{Instructions, PipelineKind}

  @types %{
    pipeline_id: :binary_id,
    project_id: :binary_id,
    runner_id: :binary_id,
    directory: :string,
    focus: :string,
    feedback: :string
  }
  @history 20
  @usage_days 90

  @impl true
  def name, do: "improve"

  @impl true
  def label, do: "Melhoria de pipeline"

  @impl true
  def icon, do: "hero-arrow-trending-up"

  @impl true
  def changeset(attrs, workspace) do
    changeset =
      {%{}, @types}
      |> Changeset.cast(attrs, [:pipeline_id, :project_id, :focus, :feedback])
      |> Changeset.validate_required([:pipeline_id])
      |> Changeset.validate_required([:project_id], message: "escolha um projeto")
      |> Changeset.validate_length(:focus, max: 4_000)
      |> Changeset.validate_length(:feedback, max: 4_000)

    case Changeset.get_field(changeset, :pipeline_id) do
      nil ->
        changeset

      id ->
        if Enum.any?(Pipelines.list_pipelines(workspace), &(&1.id == id)),
          do: changeset,
          else: Changeset.add_error(changeset, :pipeline_id, "não é um pipeline deste workspace")
    end
  end

  @impl true
  def job(input, workspace, previous) do
    pipeline = Pipelines.get_pipeline!(workspace, input.pipeline_id)
    project = Projects.get_project(workspace, input.project_id)

    %{
      title: pipeline.name,
      prompt: """
      Melhore o pipeline **#{pipeline.name}** e as notas do projeto do diretório
      `#{input.directory}`, a partir de como o pipeline vem funcionando.
      #{if input[:focus], do: "\nFoco pedido pela pessoa:\n\n#{input.focus}\n"}
      #{Instructions.revision(previous && previous.structured_output, input[:feedback])}

      ## O pipeline atual (v#{pipeline.version})

      ```yaml
      #{Instructions.cut(Yaml.to_yaml(uncapped(pipeline)), 8_000)}
      ```

      ## O projeto do diretório

      #{project_section(project)}

      ## Como ele vem funcionando

      #{usage_section(workspace, pipeline)}

      #{history_section(pipeline)}
      """,
      system_prompt: system_prompt(),
      output_schema: schema(),
      scratch: true,
      timeout_ms: 20 * 60 * 1000
    }
  end

  # The agent never sees the pipeline's cost caps: they are the person's.
  defp uncapped(%Pipeline{} = pipeline) do
    %{
      pipeline
      | max_task_cost_usd: nil,
        stages: Enum.map(pipeline.stages, &%{&1 | max_budget_usd: nil})
    }
  end

  defp project_section(nil), do: "Ainda não configurado."

  defp project_section(project) do
    """
    - setup: `#{project.setup_command || ""}`
    - teste: `#{project.test_command || ""}`
    - lint: `#{project.lint_command || ""}`

    Notas atuais:

    #{Instructions.cut(project.notes || "(nenhuma)", 3_000)}
    """
  end

  defp usage_section(workspace, %Pipeline{name: name}) do
    since = DateTime.add(DateTime.utc_now(), -@usage_days, :day)

    stages =
      workspace
      |> Usage.report(since)
      |> Map.fetch!(:by_stage)
      |> Enum.filter(&(&1.pipeline == name))

    if stages == [] do
      "Sem execuções nos últimos #{@usage_days} dias."
    else
      "Por etapa, nos últimos #{@usage_days} dias:\n\n" <>
        Enum.map_join(stages, "\n", fn stage ->
          "- #{stage.name}: #{stage.runs} execuções, #{stage.failed} falharam, " <>
            "US$ #{stage.cost_usd || 0}, #{div(stage.duration_ms || 0, 1000)} s no total"
        end)
    end
  end

  @doc "The digest of `pipeline`'s latest finished tasks the agent reads."
  @spec history_section(Pipeline.t()) :: String.t()
  def history_section(%Pipeline{} = pipeline) do
    case Tasks.history(pipeline, @history) do
      [] ->
        "Nenhuma tarefa concluída ainda: proponha a partir do código e do pipeline."

      tasks ->
        "As últimas #{length(tasks)} tarefas, da mais nova à mais antiga:\n\n" <>
          (tasks |> Enum.map_join("\n", &task_digest/1) |> Instructions.cut(14_000))
    end
  end

  defp task_digest(task) do
    stages =
      task.stage_runs
      |> Enum.group_by(& &1.name)
      |> Enum.map_join("\n", fn {name, runs} -> "  - #{name}: " <> runs_digest(runs) end)

    decisions =
      Enum.map_join(task.decisions, "\n", fn decision ->
        "  - parou: #{Instructions.cut(decision.question, 300)} → #{decision.action}" <>
          if(decision.instructions,
            do: " (#{Instructions.cut(decision.instructions, 300)})",
            else: ""
          )
      end)

    "### #{task.title} (#{task.status})\n#{stages}\n#{decisions}"
  end

  defp runs_digest(runs) do
    failed_gates =
      for run <- runs,
          gate <- (run.job && run.job.gates) || [],
          gate["passed"] == false,
          uniq: true,
          do: "`#{gate["command"]}`"

    errors =
      for run <- runs, run.error, uniq: true, do: Instructions.cut(run.error, 200)

    [
      "#{length(runs)} tentativa(s)",
      Enum.any?(runs, &(&1.status == :blocked)) && "bloqueou",
      failed_gates != [] && "gates reprovados: #{Enum.join(failed_gates, ", ")}",
      errors != [] && "erros: #{Enum.join(errors, "; ")}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp system_prompt do
    """
    # Você está melhorando um pipeline do PipeMaestro

    Você recebe o pipeline, o projeto e um resumo de como as últimas tarefas correram: onde
    as etapas falharam, que gates não passaram, onde a tarefa parou para uma pessoa e o que
    ela decidiu, e quanto cada etapa custou.

    #{Instructions.study_project()}

    ## O que propor

    - O pipeline revisado e completo (não só as mudanças): prompts mais específicos onde
      o agente errou, gates que pegariam o problema mais cedo, regras onde a tarefa
      deveria parar, etapas a juntar, dividir ou tirar, modelos mais baratos onde a etapa
      é simples. Mantenha o que funciona.
    - As notas do projeto revisadas: o que os agentes precisam saber e as decisões das
      pessoas mostram que não sabiam (convenções, armadilhas, comandos).
    - Em `mudancas`, cada mudança: onde, o quê e por quê, ligada ao que o histórico mostra.

    #{Instructions.pipeline_format()}

    Responda no formato pedido, com `analise` (Markdown: o que o histórico mostra), em
    português.
    """
  end

  @doc "The JSON Schema of the answer."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "$comment" => "pipemaestro-kind:improve",
      "required" => ["analise", "mudancas", "pipeline", "notas"],
      "properties" => %{
        "analise" => %{"type" => "string"},
        "mudancas" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["onde", "o_que", "por_que"],
            "properties" => %{
              "onde" => %{"type" => "string"},
              "o_que" => %{"type" => "string"},
              "por_que" => %{"type" => "string"}
            }
          }
        },
        "pipeline" => PipelineKind.pipeline_schema(),
        "notas" => %{"type" => "string"}
      }
    }
  end

  @impl true
  def result(output, job) do
    case output["pipeline"] do
      %{"stages" => [_ | _]} = pipeline ->
        input = Proposals.input(job)
        current = Pipelines.get_pipeline(job.workspace_id, input["pipeline_id"])

        {:ok,
         %{
           analysis: Proposals.text(output["analise"]),
           changes:
             for %{} = change <- List.wrap(output["mudancas"]) do
               %{
                 where: Proposals.text(change["onde"]),
                 what: Proposals.text(change["o_que"]),
                 why: Proposals.text(change["por_que"])
               }
             end,
           pipeline_id: input["pipeline_id"],
           project_id: input["project_id"],
           pipeline: pipeline |> Yaml.from_map() |> Yaml.without_caps() |> with_caps_of(current),
           notes: Proposals.text(output["notas"])
         }}

      _incomplete ->
        {:error, "O agente não devolveu o pipeline revisado com etapas."}
    end
  end

  # The revision keeps the caps the pipeline has now: its own and, on each
  # stage whose key is still there, the stage's. A pipeline gone has none.
  defp with_caps_of(attrs, nil), do: attrs

  defp with_caps_of(attrs, %Pipeline{} = pipeline) do
    caps = Map.new(pipeline.stages, &{&1.key, &1.max_budget_usd})

    attrs
    |> put_cap("max_task_cost_usd", pipeline.max_task_cost_usd)
    |> Map.merge(merge_settings(pipeline))
    |> Map.put("auto_analysis", pipeline.auto_analysis)
    |> Map.update!("stages", fn stages ->
      Enum.map(stages, &put_cap(&1, "max_budget_usd", caps[&1["key"]]))
    end)
  end

  # Merging the pull request, like analysing failures, is a person's choice:
  # the improved pipeline keeps the current one's.
  defp merge_settings(%Pipeline{auto_merge: true} = pipeline),
    do: %{
      "auto_merge" => true,
      "merge_method" => pipeline.merge_method,
      "max_merge_fixes" => pipeline.max_merge_fixes
    }

  defp merge_settings(_pipeline), do: %{}

  defp put_cap(attrs, _key, nil), do: attrs
  defp put_cap(attrs, key, cap), do: Map.put(attrs, key, Decimal.to_string(cap))
end
