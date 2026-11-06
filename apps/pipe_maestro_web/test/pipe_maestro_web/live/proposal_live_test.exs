defmodule PipeMaestroWeb.ProposalLiveTest do
  use PipeMaestroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Pipelines, Projects, Proposals, Runners, Tasks}
  alias PipeMaestroWeb.RunnerStatus

  @directories [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}]

  @pipeline %{
    "name" => "Entrega do App",
    "delivery" => "pr",
    "stages" => [
      %{"key" => "plano", "name" => "Plano", "prompt" => "Planeje: {{tarefa.descricao}}"},
      %{
        "key" => "codigo",
        "name" => "Código",
        "prompt" => "Implemente.",
        "gates" => ["{{projeto.teste}}"],
        "max_attempts" => 3
      }
    ]
  }

  @pipeline_output %{
    "analise" => "Um app **Phoenix**.",
    "verificacoes" => [
      %{"comando" => "mix test", "passou" => true},
      %{"comando" => "mix credo", "passou" => false, "observacao" => "2 avisos"}
    ],
    "projeto" => %{"nome" => "App", "teste" => "mix test", "copy_paths" => ["deps"]},
    "pipeline" => @pipeline
  }

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{directories: @directories, capabilities: ["scratch"]})
      )

    {old, _token} = runner_fixture(workspace, user, %{name: "antigo"})
    %{runner: runner, old: with_directories(old, @directories)}
  end

  defp bring_online(runner) do
    test_pid = self()

    spawn_link(fn ->
      {:ok, _ref} = RunnerStatus.track(self(), runner)
      send(test_pid, :tracked)
      Process.sleep(:infinity)
    end)

    assert_receive :tracked
  end

  defp ask(ctx, kind, attrs) do
    base = %{"runner_id" => ctx.runner.id, "directory" => "app"}
    {:ok, job} = Proposals.request(kind, ctx.user, ctx.workspace, Map.merge(base, attrs))
    job
  end

  defp finish(ctx, job, attrs) do
    {:ok, _started} = Jobs.mark_started(ctx.runner, job.id)
    {:ok, job} = Jobs.finish_job(ctx.runner, job.id, attrs)
    job
  end

  defp succeed(ctx, job, output),
    do: finish(ctx, job, %{"status" => "succeeded", "structured_output" => output})

  defp proposal_path(ctx, job), do: ~p"/w/#{ctx.workspace.slug}/proposals/#{job.id}"

  describe "asking" do
    test "pipelines: a capable runner studies one of its git directories", ctx do
      bring_online(ctx.runner)
      bring_online(ctx.old)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines")

      view |> element("[data-testid=generate-pipeline]") |> render_click()
      runners = view |> element("[data-testid=proposal-request-runner]") |> render()
      assert runners =~ "mac"
      assert runners =~ ~r/<option disabled[^>]*>antigo \(atualize o runner\)/

      view
      |> form("#proposal-request-form", proposal: %{runner_id: ctx.runner.id})
      |> render_change()

      directories = view |> element("[data-testid=proposal-request-directory]") |> render()
      assert directories =~ "app"
      refute directories =~ "notas"

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#proposal-request-form",
          proposal: %{runner_id: ctx.runner.id, directory: "app", request: "Entregar com PR"}
        )
        |> render_submit()

      [job] = Proposals.list_recent(ctx.workspace)
      assert path == proposal_path(ctx, job)
      assert Proposals.kind(job) == "pipeline"
    end

    test "a request without a runner or text shows what is missing", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines")
      view |> element("[data-testid=generate-pipeline]") |> render_click()
      assert has_element?(view, "[data-testid=proposal-request-no-runners]")

      html = view |> form("#proposal-request-form", proposal: %{request: ""}) |> render_submit()
      assert html =~ "escolha um runner online"
      assert html =~ "conte o que o pipeline deve fazer"
    end

    test "tasks: an idea, optionally from an issue", ctx do
      bring_online(ctx.runner)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      view |> element("[data-testid=task-generate]") |> render_click()
      assert has_element?(view, "[data-testid=proposal-request-issue-url]")

      view
      |> form("#proposal-request-form", proposal: %{runner_id: ctx.runner.id})
      |> render_change()

      {:error, {:live_redirect, _}} =
        view
        |> form("#proposal-request-form",
          proposal: %{
            runner_id: ctx.runner.id,
            directory: "app",
            request: "O login trava",
            issue_url: "https://github.com/acme/app/issues/3"
          }
        )
        |> render_submit()

      [job] = Proposals.list_recent(ctx.workspace, ["task"])
      assert Proposals.input(job)["issue_url"] == "https://github.com/acme/app/issues/3"
    end

    test "tasks: a pipeline to write for, and auto-approval on by default", ctx do
      bring_online(ctx.runner)
      pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Funcionalidade"})
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      view |> element("[data-testid=task-generate]") |> render_click()

      assert has_element?(
               view,
               "select[data-testid=proposal-request-pipeline] option[value='']",
               "Deixar o agente escolher"
             )

      refute has_element?(view, "select[data-testid=proposal-request-pipeline] option[selected]")

      assert has_element?(
               view,
               "select[data-testid=proposal-request-pipeline] option[value='#{pipeline.id}']",
               "Funcionalidade"
             )

      assert has_element?(view, "input[data-testid=proposal-request-auto-approve][checked]")

      view
      |> form("#proposal-request-form", proposal: %{runner_id: ctx.runner.id})
      |> render_change()

      {:error, {:live_redirect, _}} =
        view
        |> form("#proposal-request-form",
          proposal: %{
            runner_id: ctx.runner.id,
            directory: "app",
            request: "Exportar CSV",
            pipeline_id: pipeline.id
          }
        )
        |> render_submit()

      [job] = Proposals.list_recent(ctx.workspace, ["task"])
      assert Proposals.input(job)["pipeline_id"] == pipeline.id
      assert Proposals.input(job)["auto_approve"] == true
    end

    test "tasks: auto-approval can be turned off", ctx do
      bring_online(ctx.runner)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      view |> element("[data-testid=task-generate]") |> render_click()

      view
      |> form("#proposal-request-form", proposal: %{runner_id: ctx.runner.id})
      |> render_change()

      {:error, {:live_redirect, _}} =
        view
        |> form("#proposal-request-form",
          proposal: %{
            runner_id: ctx.runner.id,
            directory: "app",
            request: "Exportar CSV",
            auto_approve: "false"
          }
        )
        |> render_submit()

      [job] = Proposals.list_recent(ctx.workspace, ["task"])
      assert Proposals.input(job)["auto_approve"] == false
      refute Map.has_key?(Proposals.input(job), "pipeline_id")
    end

    test "improvements: a pipeline, from the directory its tasks ran in", ctx do
      bring_online(ctx.runner)
      pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Entrega"})
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines")

      view |> element("[data-testid=pipeline-improve-Entrega]") |> render_click()
      assert has_element?(view, "[data-testid=proposal-request-focus]")
      refute has_element?(view, "[data-testid=proposal-request-text]")

      view
      |> form("#proposal-request-form", proposal: %{runner_id: ctx.runner.id})
      |> render_change()

      {:error, {:live_redirect, _}} =
        view
        |> form("#proposal-request-form",
          proposal: %{runner_id: ctx.runner.id, directory: "app", focus: "Custo"}
        )
        |> render_submit()

      [job] = Proposals.list_recent(ctx.workspace, ["improve"])
      assert Proposals.input(job)["pipeline_id"] == pipeline.id
    end
  end

  describe "the proposals page" do
    test "lists every kind, filters by one and follows their status", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/proposals")
      assert has_element?(view, "[data-testid=no-proposals]")

      pipeline = ask(ctx, "pipeline", %{"request" => "Um pipeline"})
      task = ask(ctx, "task", %{"request" => "Uma tarefa"})

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/proposals")
      assert has_element?(view, "[data-testid=proposal-link-#{pipeline.id}]", "Um pipeline")
      assert has_element?(view, "[data-testid=proposal-status-#{task.id}]", "Na fila")

      view |> form("#proposals-filter", filter: %{kind: "task"}) |> render_change()
      refute has_element?(view, "[data-testid=proposal-link-#{pipeline.id}]")
      assert has_element?(view, "[data-testid=proposal-link-#{task.id}]")

      succeed(ctx, task, %{})
      assert has_element?(view, "[data-testid=proposal-status-#{task.id}]", "Concluído")
    end
  end

  describe "pipeline" do
    test "follows the analysis live, then saves the project and fills the pipeline form", ctx do
      job = ask(ctx, "pipeline", %{"request" => "Entregar *issues* com PR"})
      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=proposal-kind]", "Pipeline e projeto")
      assert has_element?(view, "[data-testid=proposal-request] em", "issues")
      assert has_element?(view, "[data-testid=proposal-waiting]")

      succeed(ctx, job, @pipeline_output)
      assert has_element?(view, "[data-testid=proposal-analysis] strong", "Phoenix")
      assert has_element?(view, "[data-testid=proposal-checks]", "2 avisos")
      assert has_element?(view, "[data-testid=proposal-stage-1]", "{{projeto.teste}}")

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#proposal-project-form", project: %{lint_command: "mix credo"})
        |> render_submit()

      assert path == ~p"/w/#{ctx.workspace.slug}/pipelines/new?proposta=#{job.id}"

      assert %{name: "App", lint_command: "mix credo"} =
               Projects.for_directory(ctx.workspace, "app")

      {:ok, form, _html} = live(ctx.conn, path)
      assert has_element?(form, "[data-testid=pipeline-from-proposal]")
      assert form |> element("[data-testid=stage-gates-1]") |> render() =~ "{{projeto.teste}}"
      {:error, {:live_redirect, _}} = form |> form("#pipeline-form") |> render_submit()

      assert [%{name: "Entrega do App", stages: [_, %{max_attempts: 3}]}] =
               Pipelines.list_pipelines(ctx.workspace)
    end

    test "a cost cap the agent proposes does not reach the form", ctx do
      job = ask(ctx, "pipeline", %{"request" => "Entregar issues com PR"})

      capped =
        @pipeline
        |> Map.put("max_task_cost_usd", 40)
        |> Map.update!("stages", fn [first | rest] ->
          [Map.put(first, "max_budget_usd", 2) | rest]
        end)

      succeed(ctx, job, Map.put(@pipeline_output, "pipeline", capped))

      {:ok, form, _html} =
        live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/new?proposta=#{job.id}")

      refute form |> element("[data-testid=pipeline-max-cost]") |> render() =~ ~s(value="40")
      refute form |> element("[data-testid=stage-budget-0]") |> render() =~ ~s(value="2")
      {:error, {:live_redirect, _}} = form |> form("#pipeline-form") |> render_submit()

      assert [%{max_task_cost_usd: nil, stages: [%{max_budget_usd: nil}, _]}] =
               Pipelines.list_pipelines(ctx.workspace)
    end

    test "a failed proposal says why and can be asked again with a comment", ctx do
      job =
        finish(ctx, ask(ctx, "pipeline", %{"request" => "x"}), %{
          "status" => "failed",
          "error" => "sem créditos"
        })

      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=proposal-error]", "sem créditos")

      view |> element("[data-testid=proposal-regenerate]") |> render_click()

      {:error, {:live_redirect, %{to: path}}} =
        view |> form("#feedback-form", round: %{feedback: "Só duas etapas"}) |> render_submit()

      next = Enum.find(Proposals.list_recent(ctx.workspace), &(&1.id != job.id))
      assert path == proposal_path(ctx, next)
      assert next.prompt =~ "Só duas etapas"
    end
  end

  describe "task" do
    test "opens the new-task form filled with the task the agent wrote", ctx do
      bring_online(ctx.runner)
      pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})
      job = ask(ctx, "task", %{"request" => "O login trava"})

      job =
        succeed(ctx, job, %{
          "analise" => "O lock não tem timeout.",
          "titulo" => "Destravar o login",
          "descricao" => "## Problema\n\nO `Auth` espera sem timeout.",
          "pipeline" => "Correção de bug",
          "pronta" => false,
          "perguntas" => ["Qual o timeout?"]
        })

      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=proposal-task-title]", "Destravar o login")
      assert has_element?(view, "[data-testid=proposal-task-prompt] h2", "Problema")
      assert has_element?(view, "[data-testid=proposal-task-ready]", "Ainda não")
      assert has_element?(view, "[data-testid=proposal-task-questions]", "Qual o timeout?")
      assert has_element?(view, "[data-testid=proposal-task-pipeline]", "Correção de bug")

      {:ok, tasks, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks?proposta=#{job.id}")
      assert has_element?(tasks, "[data-testid=task-from-proposal]")
      assert tasks |> element("[data-testid=task-title]") |> render() =~ "Destravar o login"

      {:error, {:live_redirect, _}} = tasks |> form("#new-task-form") |> render_submit()

      assert [%{title: "Destravar o login", pipeline_id: pipeline_id}] =
               Tasks.list_tasks(ctx.workspace)

      assert pipeline_id == pipeline.id
    end
  end

  describe "task auto-approval" do
    @task_output %{
      "analise" => "O lock não tem timeout.",
      "titulo" => "Destravar o login",
      "descricao" => "## Problema\n\nO `Auth` espera sem timeout.",
      "pipeline" => "Correção de bug",
      "pronta" => true
    }

    setup ctx do
      %{pipeline: pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})}
    end

    test "a task created from the proposal is linked in place of the create button", ctx do
      job = ask(ctx, "task", %{"request" => "O login trava", "auto_approve" => "true"})
      job = succeed(ctx, job, @task_output)
      [task] = Tasks.list_tasks(ctx.workspace)

      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      refute has_element?(view, "[data-testid=proposal-create-task]")
      refute has_element?(view, "[data-testid=proposal-auto-approve-skipped]")

      assert view |> element("[data-testid=proposal-created-task-link]") |> render() =~
               "/w/#{ctx.workspace.slug}/tasks/#{task.id}"
    end

    test "a proposal that could not be created on its own says why", ctx do
      job = ask(ctx, "task", %{"request" => "O login trava", "auto_approve" => "true"})

      job =
        succeed(
          ctx,
          job,
          %{@task_output | "pronta" => false}
          |> Map.put("perguntas", ["Qual o timeout?"])
        )

      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=proposal-create-task]")
      refute has_element?(view, "[data-testid=proposal-created-task-link]")

      assert has_element?(
               view,
               "[data-testid=proposal-auto-approve-skipped]",
               "Qual o timeout?"
             )
    end

    test "with the page open, the task created on its own takes the person to it", ctx do
      job = ask(ctx, "task", %{"request" => "O login trava", "auto_approve" => "true"})
      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))

      succeed(ctx, job, @task_output)
      [task] = Tasks.list_tasks(ctx.workspace)

      {path, _flash} = assert_redirect(view)
      assert path == "/w/#{ctx.workspace.slug}/tasks/#{task.id}"
    end

    test "the new-task form of a proposal already turned into a task goes to it", ctx do
      job = ask(ctx, "task", %{"request" => "O login trava", "auto_approve" => "true"})
      job = succeed(ctx, job, @task_output)
      [task] = Tasks.list_tasks(ctx.workspace)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks?proposta=#{job.id}")

      assert to == "/w/#{ctx.workspace.slug}/tasks/#{task.id}"
    end

    test "the form links the task it creates to the proposal", ctx do
      bring_online(ctx.runner)
      job = ask(ctx, "task", %{"request" => "O login trava", "auto_approve" => "false"})
      job = succeed(ctx, job, @task_output)
      assert Tasks.list_tasks(ctx.workspace) == []

      {:ok, tasks, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks?proposta=#{job.id}")
      {:error, {:live_redirect, _}} = tasks |> form("#new-task-form") |> render_submit()

      assert [task] = Tasks.list_tasks(ctx.workspace)
      assert task.proposal_job_id == job.id

      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=proposal-created-task-link]")
    end
  end

  describe "decision" do
    setup ctx do
      pipeline = pipeline_fixture(ctx.workspace)

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "Corrigir o login",
          "prompt" => "O botão não responde",
          "pipeline_id" => pipeline.id,
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })

      job = hd(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, job.id, %{
          "status" => "succeeded",
          "structured_output" => %{"status" => "bloqueado", "resumo" => "Qual navegador?"}
        })

      %{task: Tasks.get_task!(ctx.workspace, task.id)}
    end

    test "is asked from the task and from the decisions page", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{ctx.task.id}")

      {:error, {:live_redirect, %{to: path}}} =
        view |> element("[data-testid=decision-suggest]") |> render_click()

      [job] = Proposals.list_recent(ctx.workspace, ["decision"])
      assert path == proposal_path(ctx, job)

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/decisions")

      {:error, {:live_redirect, _}} =
        view |> element("[data-testid=decision-suggest-#{ctx.task.id}]") |> render_click()

      assert length(Proposals.list_recent(ctx.workspace, ["decision"])) == 2
    end

    test "applies the suggested decision with the instructions as left", ctx do
      {:ok, job} =
        Proposals.request("decision", ctx.user, ctx.workspace, %{"task_id" => ctx.task.id})

      job =
        succeed(ctx, job, %{
          "diagnostico" => "Falta o **navegador**.",
          "acao" => "retry",
          "instrucoes" => "Reproduza no Chrome.",
          "alternativas" => [%{"acao" => "cancel", "motivo" => "Se não reproduzir"}]
        })

      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=proposal-diagnosis] strong", "navegador")
      assert has_element?(view, "[data-testid=proposal-alternatives]", "Se não reproduzir")
      assert has_element?(view, "[data-testid=proposal-task-link]")

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#proposal-decision-form", decision: %{instructions: "Reproduza no Safari."})
        |> render_submit(%{"action" => "retry"})

      assert path == ~p"/w/#{ctx.workspace.slug}/tasks/#{ctx.task.id}"
      task = Tasks.get_task!(ctx.workspace, ctx.task.id)
      assert task.status == :running
      assert List.last(task.stage_runs).instructions =~ "Reproduza no Safari."

      # Once decided, the proposal says so and does not decide again.
      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=proposal-decision-stale]")
    end
  end

  describe "analysis" do
    test "the analysis a block asked for is read on its page, to answer on the task", ctx do
      pipeline = pipeline_fixture(ctx.workspace)

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "Corrigir o login",
          "prompt" => "O botão não responde",
          "pipeline_id" => pipeline.id,
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })

      stage_job = hd(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job

      succeed(ctx, stage_job, %{"status" => "bloqueado", "resumo" => "Algo deu errado"})

      task = Tasks.get_task!(ctx.workspace, task.id)
      job = Jobs.get_job!(ctx.workspace, task.decision_analysis_job_id)

      job =
        succeed(ctx, job, %{
          "diagnostico" => "Falta o **timeout**.",
          "perguntas" => [
            %{
              "titulo" => "Correção",
              "pergunta" => "Como corrigir a falha?",
              "multipla" => false,
              "opcoes" => [
                %{"rotulo" => "Aumentar", "descricao" => "", "recomendada" => true},
                %{"rotulo" => "Desistir", "descricao" => "", "recomendada" => false}
              ]
            }
          ]
        })

      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=questionnaire-diagnosis] strong", "timeout")
      assert has_element?(view, "[data-testid=question-0]", "Como corrigir a falha?")
      refute has_element?(view, "[data-testid=proposal-analysis-stale]")
      refute has_element?(view, "[data-testid=questionnaire-submit]")

      {:ok, _} = Tasks.retry_stage(task, nil, by: ctx.user)
      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=proposal-analysis-stale]")
    end
  end

  describe "decision guards" do
    setup ctx do
      pipeline = pipeline_fixture(ctx.workspace)

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "Corrigir o login",
          "prompt" => "x",
          "pipeline_id" => pipeline.id,
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })

      block!(ctx, task)
      task = Tasks.get_task!(ctx.workspace, task.id)

      {:ok, job} =
        Proposals.request("decision", ctx.user, ctx.workspace, %{"task_id" => task.id})

      job =
        succeed(ctx, job, %{"diagnostico" => "x", "acao" => "retry", "instrucoes" => "Siga."})

      %{task: task, proposal: job}
    end

    defp block!(ctx, task) do
      run = Tasks.get_task!(ctx.workspace, task.id).stage_runs |> List.last()
      {:ok, _} = Jobs.mark_started(ctx.runner, run.job.id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, run.job.id, %{
          "status" => "succeeded",
          "structured_output" => %{"status" => "bloqueado", "resumo" => "?"}
        })
    end

    test "a suggestion for an earlier pause does not decide a later one", ctx do
      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, ctx.proposal))
      refute has_element?(view, "[data-testid=proposal-decision-stale]")

      # Someone decides elsewhere, and the task stops again at the same stage.
      {:ok, _} = Tasks.retry_stage(ctx.task, "outra coisa", by: ctx.user)
      block!(ctx, ctx.task)
      assert Tasks.get_task!(ctx.workspace, ctx.task.id).status == :awaiting_decision
      assert has_element?(view, "[data-testid=proposal-decision-stale]")

      html = render_submit(view, "apply_decision", %{"action" => "retry", "decision" => %{}})
      assert html =~ "A tarefa não espera mais esta decisão."
      assert length(Tasks.list_decisions(ctx.task)) == 1
    end

    test "cancelling follows who may cancel the task; an unknown action is refused", ctx do
      other = member_fixture(ctx.workspace)
      conn = log_in_user(build_conn(), other)
      {:ok, view, _html} = live(conn, proposal_path(ctx, ctx.proposal))
      assert has_element?(view, "[data-testid=proposal-decision-cancel][disabled]")

      html = render_submit(view, "apply_decision", %{"action" => "cancel", "decision" => %{}})
      assert html =~ "Só quem criou a tarefa ou um admin a cancela."

      html = render_submit(view, "apply_decision", %{"action" => "pular", "decision" => %{}})
      assert html =~ "Escolha tentar de novo, avançar ou cancelar."
      assert Tasks.get_task!(ctx.workspace, ctx.task.id).status == :awaiting_decision

      # Nor does the other member stop someone else's proposal.
      {:ok, running} =
        Proposals.request("decision", ctx.user, ctx.workspace, %{"task_id" => ctx.task.id})

      {:ok, view, _html} = live(conn, proposal_path(ctx, running))
      html = render_click(view, "cancel", %{})
      assert html =~ "Só quem pediu a proposta ou um admin a cancela."
    end
  end

  describe "the proposals page filters" do
    test "by status, directory and who asked", ctx do
      other = member_fixture(ctx.workspace, %{name: "Bruno"})
      mine = ask(ctx, "pipeline", %{"request" => "Meu"})

      {:ok, theirs} =
        Proposals.request("task", other, ctx.workspace, %{
          "runner_id" => ctx.runner.id,
          "directory" => "app",
          "request" => "Deles"
        })

      succeed(ctx, theirs, %{})
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/proposals")

      view |> form("#proposals-filter", filter: %{status: "active"}) |> render_change()
      assert has_element?(view, "[data-testid=proposal-link-#{mine.id}]")
      refute has_element?(view, "[data-testid=proposal-link-#{theirs.id}]")

      view
      |> form("#proposals-filter", filter: %{status: "", user_id: other.id})
      |> render_change()

      refute has_element?(view, "[data-testid=proposal-link-#{mine.id}]")
      assert has_element?(view, "[data-testid=proposal-link-#{theirs.id}]")

      view
      |> form("#proposals-filter", filter: %{user_id: "", directory: "app", status: "canceled"})
      |> render_change()

      assert has_element?(
               view,
               "[data-testid=no-proposals]",
               "Nenhuma proposta com esses filtros"
             )
    end
  end

  describe "improve" do
    test "saves the notes and opens the pipeline's form with the revision", ctx do
      pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Entrega"})

      {:ok, _project} =
        Projects.create_project(ctx.workspace, %{"name" => "App", "directory" => "app"})

      job = ask(ctx, "improve", %{"pipeline_id" => pipeline.id})

      job =
        succeed(ctx, job, %{
          "analise" => "O gate falha muito.",
          "mudancas" => [
            %{"onde" => "Código", "o_que" => "gate de teste", "por_que" => "falhou 3x"}
          ],
          "pipeline" => @pipeline,
          "notas" => "Rode `mix test` antes."
        })

      {:ok, view, _html} = live(ctx.conn, proposal_path(ctx, job))
      assert has_element?(view, "[data-testid=proposal-changes]", "falhou 3x")
      view |> form("#proposal-notes-form", notes: %{notes: "Rode mix test."}) |> render_submit()
      assert Projects.for_directory(ctx.workspace, "app").notes == "Rode mix test."

      {:error, {:live_redirect, %{to: path}}} =
        view |> element("[data-testid=proposal-review-pipeline]") |> render_click()

      assert path ==
               ~p"/w/#{ctx.workspace.slug}/pipelines/#{pipeline.id}/edit?proposta=#{job.id}"

      {:ok, form, _html} = live(ctx.conn, path)
      assert render(form) =~ "vira a versão 2"
      {:error, {:live_redirect, _}} = form |> form("#pipeline-form") |> render_submit()

      assert %{version: 2, name: "Entrega do App"} =
               Pipelines.get_pipeline!(ctx.workspace, pipeline.id)
    end

    test "the revision keeps the pipeline's own cost caps", ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "name" => "Entrega",
          "max_task_cost_usd" => "40",
          "stages" => [
            %{"key" => "plano", "name" => "Plano", "prompt" => "p", "max_budget_usd" => "1.5"}
          ]
        })

      job = ask(ctx, "improve", %{"pipeline_id" => pipeline.id})
      capped = Map.put(@pipeline, "max_task_cost_usd", 5)
      succeed(ctx, job, %{"analise" => "x", "mudancas" => [], "pipeline" => capped})

      {:ok, form, _html} =
        live(
          ctx.conn,
          ~p"/w/#{ctx.workspace.slug}/pipelines/#{pipeline.id}/edit?proposta=#{job.id}"
        )

      assert form |> element("[data-testid=pipeline-max-cost]") |> render() =~ ~s(value="40")
      assert form |> element("[data-testid=stage-budget-0]") |> render() =~ ~s(value="1.5")
      refute form |> element("[data-testid=stage-budget-1]") |> render() =~ ~s(value=")
    end

    test "a proposal named on another pipeline's form is ignored", ctx do
      pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Entrega"})
      other = pipeline_fixture(ctx.workspace, %{"name" => "Outro"})
      job = ask(ctx, "improve", %{"pipeline_id" => pipeline.id})

      succeed(ctx, job, %{
        "analise" => "x",
        "mudancas" => [],
        "pipeline" => @pipeline,
        "notas" => ""
      })

      {:ok, form, _html} =
        live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/pipelines/#{other.id}/edit?proposta=#{job.id}")

      assert form |> element("[data-testid=pipeline-name]") |> render() =~ "Outro"
      refute render(form) =~ "Entrega do App"
    end
  end
end
