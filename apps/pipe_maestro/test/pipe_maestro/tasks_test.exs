defmodule PipeMaestro.TasksTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, Pipelines, Tasks}
  alias PipeMaestro.Tasks.{StageRun, Task}

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)

    runner =
      with_directories(runner, [
        %{"name" => "app", "git" => true},
        %{"name" => "notas", "git" => false}
      ])

    %{workspace: workspace, user: user, runner: runner, pipeline: pipeline_fixture(workspace)}
  end

  defp create_task(ctx, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        ctx.user,
        ctx.workspace,
        Enum.into(attrs, %{
          "title" => "Corrigir o login",
          "prompt" => "O botão de login não responde",
          "pipeline_id" => ctx.pipeline.id,
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })
      )

    task
  end

  defp current_job(task) do
    task =
      Tasks.get_task!(%PipeMaestro.Workspaces.Workspace{id: task.workspace_id}, task.id)

    (Enum.find(task.stage_runs, &(&1.status == :running)) || List.last(task.stage_runs)).job
  end

  # Plays the runner: starts the task's current job and reports its end.
  defp run_current(ctx, task, report) do
    job = current_job(task)
    {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

    payload =
      Map.merge(
        %{
          "status" => "succeeded",
          "exit_code" => 0,
          "structured_output" => %{"status" => "ok", "resumo" => "feito"},
          "artifact" => "# Artefato",
          "workdir" => "/w/worktrees/#{task.id}"
        },
        report
      )

    {:ok, _job} = Jobs.finish_job(ctx.runner, job.id, payload)
    Tasks.get_task!(ctx.workspace, task.id)
  end

  describe "create_task/3" do
    test "snapshots the pipeline, names a branch and hands the first stage to the runner", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx)

      assert %Task{status: :running, current_stage: 0, git: true} = task
      assert task.pipeline_name == ctx.pipeline.name
      assert task.pipeline_version == 1
      assert Enum.map(task.stages, & &1.key) == ["a", "b"]
      assert task.branch =~ ~r"^cp/corrigir-o-login-[0-9a-f]{8}$"

      assert_receive {:job_assign, job}
      assert job.prompt =~ "Faça A: O botão de login não responde"
      assert job.context["directory"] == "app"
      assert job.context["worktree"] == %{"task_id" => task.id, "branch" => task.branch}
      assert job.context["artifact_path"] == ".control-plane/#{task.id}/01-a.md"
      assert job.context["output_schema"]["required"] == ["status", "resumo"]
      assert job.context["timeout_ms"] == 60 * 60_000

      assert [%Task{}] = Tasks.list_tasks(ctx.workspace)
    end

    test "a directory with a project sets up the worktree and fills {{projeto.*}}", ctx do
      {:ok, project} =
        PipeMaestro.Projects.create_project(ctx.workspace, %{
          "name" => "App",
          "directory" => "app",
          "setup_command" => "mix deps.get",
          "test_command" => "mix test",
          "copy_paths_text" => "deps"
        })

      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{
              "key" => "a",
              "name" => "A",
              "prompt" => "Rode {{projeto.teste}} em {{projeto.nome}}."
            }
          ]
        })

      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx, %{"pipeline_id" => pipeline.id})

      assert task.project_id == project.id
      assert task.project["test_command"] == "mix test"
      assert_receive {:job_assign, job}
      assert job.prompt =~ "Rode mix test em App."
      assert job.context["setup"] == %{"command" => "mix deps.get", "copy" => ["deps"]}

      # Editing the project does not change the task.
      {:ok, _} = PipeMaestro.Projects.update_project(project, %{"test_command" => "make"})
      assert Tasks.get_task!(ctx.workspace, task.id).project["test_command"] == "mix test"
    end

    test "the pipeline's context and the stage's agent reach the runner", ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "system_prompt" => "Nunca altere código.",
          "mcp_config_json" => ~s({"mcpServers": {}}),
          "agents_json" => ~s({"analista": {"description": "d", "prompt": "p"}}),
          "stages" => [%{"key" => "a", "name" => "A", "prompt" => "p", "agent" => "analista"}]
        })

      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx, %{"pipeline_id" => pipeline.id})
      assert_receive {:job_assign, job}

      assert job.context["system_prompt"] == "Nunca altere código."
      assert job.context["mcp_config"] == %{"mcpServers" => %{}}
      assert job.context["agents"] == %{"analista" => %{"description" => "d", "prompt" => "p"}}
      assert job.context["agent"] == "analista"

      # Kept with the task: editing the pipeline does not change it.
      {:ok, _} = Pipelines.update_pipeline(pipeline, %{"system_prompt" => "Outra coisa."})

      assert Tasks.get_task!(ctx.workspace, task.id).pipeline_context["system_prompt"] ==
               "Nunca altere código."
    end

    test "without a project, {{projeto.*}} is empty and there is no setup", ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [%{"key" => "a", "name" => "A", "prompt" => "Teste: [{{projeto.teste}}]"}]
        })

      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx, %{"pipeline_id" => pipeline.id})

      assert task.project_id == nil
      assert_receive {:job_assign, job}
      assert job.prompt =~ "Teste: []"
      refute Map.has_key?(job.context, "setup")
    end

    test "a directory without git gets no worktree", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx, %{"directory" => "notas"})

      assert %Task{git: false, branch: nil} = task
      assert_receive {:job_assign, job}
      refute Map.has_key?(job.context, "worktree")
    end

    test "validates the pipeline, runner and directory", ctx do
      assert {:error, changeset} = Tasks.create_task(ctx.user, ctx.workspace, %{})

      assert %{title: [_], prompt: [_], pipeline_id: [_], runner_id: [_], directory: [_]} =
               errors_on(changeset)

      other = workspace_fixture()
      foreign_pipeline = pipeline_fixture(other)

      base = %{
        "title" => "t",
        "prompt" => "p",
        "pipeline_id" => ctx.pipeline.id,
        "runner_id" => ctx.runner.id,
        "directory" => "app"
      }

      for {attrs, field} <- [
            {%{"pipeline_id" => foreign_pipeline.id}, :pipeline_id},
            {%{"pipeline_id" => "nope"}, :pipeline_id},
            {%{"runner_id" => Ecto.UUID.generate()}, :runner_id},
            {%{"directory" => "inexistente"}, :directory}
          ] do
        assert {:error, changeset} =
                 Tasks.create_task(ctx.user, ctx.workspace, Map.merge(base, attrs))

        assert Map.has_key?(errors_on(changeset), field), "expected an error on #{field}"
      end
    end

    test "editing the pipeline does not change a task already running", ctx do
      task = create_task(ctx)

      {:ok, _} =
        Pipelines.update_pipeline(ctx.pipeline, %{
          "stages" => [%{"key" => "z", "name" => "Z", "prompt" => "z"}]
        })

      assert Enum.map(Tasks.get_task!(ctx.workspace, task.id).stages, & &1.key) == ["a", "b"]
    end
  end

  describe "the gate" do
    test "every stage passes and the task succeeds", ctx do
      :ok = Tasks.subscribe({:task, create_task(ctx).id})
      task = Tasks.list_tasks(ctx.workspace) |> hd()

      task = run_current(ctx, task, %{})
      assert %Task{status: :running, current_stage: 1, worktree: "/w/worktrees/" <> _} = task
      assert_receive {:task_updated, %Task{current_stage: 1}}

      second = current_job(task)
      assert second.prompt =~ "- Etapa A: .control-plane/#{task.id}/01-a.md"

      task = run_current(ctx, task, %{})
      assert %Task{status: :succeeded, finished_at: %DateTime{}} = task

      assert [
               %StageRun{key: "a", status: :passed, summary: "feito", artifact: "# Artefato"},
               %StageRun{key: "b", status: :passed}
             ] = task.stage_runs
    end

    test "an error is retried, then waits for a decision", ctx do
      task = create_task(ctx)

      task = run_current(ctx, task, %{"status" => "failed", "exit_code" => 1, "error" => "boom"})
      assert %Task{status: :running, current_stage: 0} = task
      assert [%StageRun{status: :failed, error: "boom"}, %StageRun{attempt: 2}] = task.stage_runs

      task = run_current(ctx, task, %{"artifact" => nil})
      assert %Task{status: :awaiting_decision} = task
      assert task.decision_reason =~ "falhou em 2 tentativa(s)"
      assert task.decision_reason =~ "sem escrever o artefato"
    end

    test "a missing structured output is an error", ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{"structured_output" => nil})

      assert [
               %StageRun{status: :failed, error: "A etapa terminou sem a saída estruturada" <> _}
               | _
             ] =
               task.stage_runs
    end

    test "a blocked stage waits for a decision without retrying", ctx do
      task = create_task(ctx)

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "Falta o passo a passo"}
        })

      assert %Task{status: :awaiting_decision} = task
      assert task.decision_reason =~ "Falta o passo a passo"
      assert [%StageRun{status: :blocked}] = task.stage_runs
    end

    test "a stage passes on to the next by itself, also one saved with the old approval setting",
         ctx do
      {:ok, pipeline} =
        Pipelines.update_pipeline(ctx.pipeline, %{
          "stages" => [
            %{"key" => "a", "name" => "Etapa A", "prompt" => "A"},
            %{"key" => "b", "name" => "Etapa B", "prompt" => "B"}
          ]
        })

      task = create_task(%{ctx | pipeline: pipeline})

      # A task started before stages lost their approval and permission
      # settings still has them in its copy of the stages.
      PipeMaestro.Repo.query!(
        """
        UPDATE tasks SET stages = (
          SELECT jsonb_agg(s || '{"pause_after": true, "permission_profile": "leitura"}')
          FROM jsonb_array_elements(stages) s)
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(task.id)]
      )

      task = run_current(ctx, task, %{})

      assert %Task{status: :running, current_stage: 1} = task
    end

    test "a canceled job cancels the task", ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{"status" => "canceled"})
      assert %Task{status: :canceled} = task
    end

    test "a job lost by a restarted runner counts as a failed attempt", ctx do
      task = create_task(ctx)
      {:ok, _} = Jobs.mark_started(ctx.runner, current_job(task).id)

      Jobs.reconcile(ctx.runner, [])

      task = Tasks.get_task!(ctx.workspace, task.id)

      assert [%StageRun{status: :failed, error: "O runner reiniciou" <> _}, %StageRun{attempt: 2}] =
               task.stage_runs
    end
  end

  describe "gates, rules and feedback" do
    setup ctx do
      {:ok, _project} =
        PipeMaestro.Projects.create_project(ctx.workspace, %{
          "name" => "App",
          "directory" => "app",
          "test_command" => "mix test"
        })

      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{
              "key" => "a",
              "name" => "Corrigir",
              "prompt" => "Corrija.",
              "max_attempts" => 2,
              "gates_text" => "{{projeto.teste}}",
              "rules_text" => "risco == alto"
            },
            %{"key" => "b", "name" => "Revisar", "prompt" => "Revise."}
          ]
        })

      %{pipeline: pipeline}
    end

    test "the runner gets the stage's gate commands, rendered", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      create_task(ctx)
      assert_receive {:job_assign, job}
      assert job.context["gates"] == [%{"command" => "mix test", "expect" => "pass"}]
    end

    test "a job carries no permission settings: the agent runs with every permission", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      create_task(ctx)
      assert_receive {:job_assign, job}
      refute Map.has_key?(job.context, "permissions")
    end

    test "a gate that renders to nothing (no project setting) is dropped", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      create_task(ctx, %{"directory" => "notas"})
      assert_receive {:job_assign, job}
      refute Map.has_key?(job.context, "gates")
    end

    test "a gate not met fails the attempt; the next one gets feedback", ctx do
      task = create_task(ctx)

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "ok", "resumo" => "Mudei o login."},
          "gates" => [
            %{
              "command" => "mix test",
              "expect" => "pass",
              "exit_code" => 2,
              "output" => "1 test, 1 failure: LoginTest",
              "passed" => false
            }
          ]
        })

      assert [%StageRun{status: :failed, error: error}, %StageRun{attempt: 2, feedback: feedback}] =
               task.stage_runs

      assert error =~ "mix test"
      assert error =~ "esperava passar"
      assert feedback =~ error
      assert feedback =~ "Mudei o login."
      assert feedback =~ "1 failure: LoginTest"

      second = current_job(task)
      assert second.prompt =~ "A tentativa anterior desta etapa não passou"
      assert second.prompt =~ "1 failure: LoginTest"
    end

    test "gates met let the stage pass", ctx do
      task = create_task(ctx)
      gate = %{"command" => "mix test", "expect" => "pass", "exit_code" => 0, "passed" => true}
      task = run_current(ctx, task, %{"gates" => [gate]})
      assert %Task{status: :running, current_stage: 1} = task
    end

    test "a rule that matches the output pauses the task after the stage", ctx do
      task = create_task(ctx)

      output = %{"status" => "ok", "resumo" => "Feito.", "risco" => "alto"}
      task = run_current(ctx, task, %{"structured_output" => output})

      assert %Task{status: :awaiting_decision, decision_reason: reason} = task
      assert reason =~ "risco == alto"
      assert [%StageRun{status: :passed}] = task.stage_runs

      assert {:ok, %Task{status: :running, current_stage: 1}} = Tasks.advance(task, nil)
    end
  end

  describe "decisions" do
    setup ctx do
      task = create_task(ctx)

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "dúvida"}
        })

      %{task: task}
    end

    test "retry runs the stage again with the instructions", ctx do
      assert {:ok, %Task{status: :running, current_stage: 0} = task} =
               Tasks.retry_stage(ctx.task, "Use o arquivo x")

      assert [%StageRun{status: :blocked}, %StageRun{attempt: 2, instructions: "Use o arquivo x"}] =
               task.stage_runs

      assert current_job(task).prompt =~ "Use o arquivo x"
      assert Tasks.retry_stage(task, nil) == {:error, :not_awaiting}
    end

    test "advance moves on, and past the last stage the task succeeds", ctx do
      assert {:ok, %Task{status: :running, current_stage: 1} = task} =
               Tasks.advance(ctx.task, "  ")

      assert List.last(task.stage_runs).instructions == nil

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "de novo"}
        })

      assert {:ok, %Task{status: :succeeded}} = Tasks.advance(task, nil)
    end

    test "every decision is kept: the question, the options, the answer and who gave it", ctx do
      task = create_task(ctx)

      task =
        run_current(ctx, task, %{
          "structured_output" => %{
            "status" => "bloqueado",
            "resumo" => "Corrijo no cliente ou no servidor?",
            "opcoes" => ["No cliente", "No servidor"]
          }
        })

      assert Tasks.options(task) == ["No cliente", "No servidor"]

      assert {:ok, task} =
               Tasks.retry_stage(task, "e escreva um teste", by: ctx.user, choice: "No servidor")

      assert current_job(task).prompt =~ "Decisão: No servidor"
      assert current_job(task).prompt =~ "e escreva um teste"

      assert [decision] = Tasks.list_decisions(task)
      assert decision.stage_index == 0
      assert decision.question =~ "Corrijo no cliente ou no servidor?"
      assert decision.options == ["No cliente", "No servidor"]
      assert decision.action == :retry
      assert decision.choice == "No servidor"
      assert decision.instructions == "e escreva um teste"
      assert decision.decided_by_user_id == ctx.user.id
      assert %DateTime{} = decision.inserted_at

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "outra"}
        })

      assert Tasks.options(task) == []
      {:ok, task} = Tasks.cancel_task(task, by: ctx.user)
      assert [_, %{action: :cancel, choice: nil}] = Tasks.list_decisions(task)
    end

    test "cancel ends a task waiting for a decision", ctx do
      assert {:ok, %Task{status: :canceled}} = Tasks.cancel_task(ctx.task)
      assert Tasks.cancel_task(ctx.task) == {:error, :finished}
    end
  end

  describe "the decision questionnaire" do
    setup ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{"key" => "a", "name" => "Etapa A", "prompt" => "Faça A", "max_attempts" => 1},
            %{"key" => "b", "name" => "Etapa B", "prompt" => "Faça B"}
          ]
        })

      %{pipeline: pipeline}
    end

    defp agent_questions do
      [
        %{
          "titulo" => "Navegador",
          "pergunta" => "Em qual navegador reproduz?",
          "multipla" => false,
          "opcoes" => [
            %{"rotulo" => "Chrome", "descricao" => "O mais usado", "recomendada" => false},
            %{
              "rotulo" => "Safari 17",
              "descricao" => "Onde o bug apareceu",
              "recomendada" => true
            }
          ]
        },
        %{
          "titulo" => "Telas",
          "pergunta" => "Quais telas mudam?",
          "multipla" => true,
          "opcoes" => [
            %{"rotulo" => "Board", "descricao" => "", "recomendada" => true},
            %{"rotulo" => "Decisões", "descricao" => "", "recomendada" => false}
          ]
        }
      ]
    end

    defp block_with_questions(ctx, task) do
      run_current(ctx, task, %{
        "structured_output" => %{
          "status" => "bloqueado",
          "resumo" => "Preciso de duas respostas",
          "perguntas" => agent_questions()
        }
      })
    end

    defp fail_stage(ctx, task),
      do: run_current(ctx, task, %{"status" => "failed", "exit_code" => 1, "error" => "boom"})

    defp analysis_job(ctx, task) do
      task = Tasks.get_task!(ctx.workspace, task.id)
      assert is_binary(task.decision_analysis_job_id), "expected an analysis job"
      Jobs.get_job!(ctx.workspace, task.decision_analysis_job_id)
    end

    defp finish_analysis(ctx, job, payload) do
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)
      {:ok, _} = Jobs.finish_job(ctx.runner, job.id, payload)
      :ok
    end

    @analysis_output %{
      "diagnostico" => "O teste de login falha porque o **timeout** é curto.",
      "perguntas" => [
        %{
          "titulo" => "Correção",
          "pergunta" => "Como a etapa deve seguir?",
          "multipla" => false,
          "opcoes" => [
            %{
              "rotulo" => "Tentar sem falha",
              "descricao" => "Aumenta o timeout",
              "recomendada" => true
            },
            %{"rotulo" => "Desistir", "descricao" => "Cancela", "recomendada" => false}
          ]
        }
      ]
    }

    test "a block with questions keeps them, from the agent, and asks for no analysis", ctx do
      task = block_with_questions(ctx, create_task(ctx))

      assert %Task{status: :awaiting_decision} = task
      assert %{"origem" => "agente", "perguntas" => [first, second]} = task.decision_questionnaire
      # The recommended option comes first.
      assert hd(first["opcoes"])["rotulo"] == "Safari 17"
      assert second["multipla"] == true
      assert task.decision_analysis_job_id == nil

      assert %{questionnaire: %{"origem" => "agente"}, analysis: :none} =
               Tasks.questionnaire(task)
    end

    test "a block with the old options becomes a single question", ctx do
      task =
        run_current(ctx, create_task(ctx), %{
          "structured_output" => %{
            "status" => "bloqueado",
            "resumo" => "Onde corrigir?",
            "opcoes" => ["No cliente", "No servidor"]
          }
        })

      assert %{"origem" => "opcoes", "perguntas" => [question]} = task.decision_questionnaire
      assert Enum.map(question["opcoes"], & &1["rotulo"]) == ["No cliente", "No servidor"]
      assert Tasks.options(task) == ["No cliente", "No servidor"]
    end

    test "exhausted attempts ask the agent for an analysis, with no click", ctx do
      task = fail_stage(ctx, create_task(ctx))

      assert %Task{status: :awaiting_decision} = task
      assert task.decision_questionnaire == nil
      job = analysis_job(ctx, task)

      assert PipeMaestro.Proposals.kind(job) == "analysis"
      assert job.runner_id == ctx.runner.id
      assert job.created_by_user_id == ctx.user.id
      assert job.prompt =~ "boom"
      # The runner does not announce "scratch": the agent reads only the context.
      refute Map.has_key?(job.context, "directory")
      refute Map.has_key?(job.context, "scratch")
      assert job.context["output_schema"]["$comment"] == "pipemaestro-kind:analysis"
      assert job.context["max_budget_usd"] == 1

      assert %{questionnaire: nil, analysis: :running} = Tasks.questionnaire(task)
    end

    test "a block with nothing to ask is analysed like a failure", ctx do
      task =
        run_current(ctx, create_task(ctx), %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "Algo deu errado"}
        })

      assert %Task{status: :awaiting_decision} = task
      assert task.decision_questionnaire == nil
      assert PipeMaestro.Proposals.kind(analysis_job(ctx, task)) == "analysis"
    end

    test "a pause by a rule asks for no analysis", ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{"key" => "a", "name" => "A", "prompt" => "p", "rules_text" => "risco == alto"},
            %{"key" => "b", "name" => "B", "prompt" => "p"}
          ]
        })

      task = create_task(%{ctx | pipeline: pipeline})

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "ok", "resumo" => "r", "risco" => "alto"}
        })

      assert %Task{status: :awaiting_decision} = task
      assert task.decision_analysis_job_id == nil
      assert task.decision_questionnaire == nil
    end

    test "the analysis' diagnosis and questions become the task's questionnaire, live", ctx do
      task = fail_stage(ctx, create_task(ctx))
      :ok = Tasks.subscribe({:task, task.id})
      :ok = Tasks.subscribe({:decisions, ctx.workspace.id})

      job = analysis_job(ctx, task)

      finish_analysis(ctx, job, %{
        "status" => "succeeded",
        "structured_output" => @analysis_output
      })

      assert_receive {:task_updated, %Task{}}
      task = Tasks.get_task!(ctx.workspace, task.id)

      assert %{"origem" => "analise", "diagnostico" => diagnosis, "perguntas" => [question]} =
               task.decision_questionnaire

      assert diagnosis =~ "timeout"
      assert hd(question["opcoes"])["rotulo"] == "Tentar sem falha"
      assert %{questionnaire: %{"origem" => "analise"}} = Tasks.questionnaire(task)
    end

    test "an analysis that fails or is canceled leaves the manual decision working", ctx do
      task = fail_stage(ctx, create_task(ctx))
      job = analysis_job(ctx, task)
      finish_analysis(ctx, job, %{"status" => "failed", "exit_code" => 1, "error" => "sem cota"})

      task = Tasks.get_task!(ctx.workspace, task.id)
      assert task.decision_questionnaire == nil
      assert %{questionnaire: nil, analysis: :failed} = Tasks.questionnaire(task)
      assert {:ok, %Task{status: :running}} = Tasks.retry_stage(task, "Tente de novo")

      task = fail_stage(ctx, task)
      {:ok, _} = Jobs.request_cancel(analysis_job(ctx, task))
      task = Tasks.get_task!(ctx.workspace, task.id)
      assert %{questionnaire: nil, analysis: :failed} = Tasks.questionnaire(task)
      assert {:ok, %Task{status: :running, current_stage: 1}} = Tasks.advance(task, nil)
    end

    test "an invalid analysis answer gives no questionnaire", ctx do
      task = fail_stage(ctx, create_task(ctx))
      job = analysis_job(ctx, task)

      finish_analysis(ctx, job, %{
        "status" => "succeeded",
        "structured_output" => %{"diagnostico" => "x", "perguntas" => []}
      })

      task = Tasks.get_task!(ctx.workspace, task.id)
      assert task.decision_questionnaire == nil
      assert %{analysis: :failed} = Tasks.questionnaire(task)
    end

    test "deciding cancels the analysis, and one that ends later is ignored", ctx do
      task = fail_stage(ctx, create_task(ctx))
      job = analysis_job(ctx, task)
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

      {:ok, task} = Tasks.retry_stage(task, "Tente de novo", by: ctx.user)
      assert %DateTime{} = Jobs.get_job!(ctx.workspace, job.id).cancel_requested_at

      {:ok, _} =
        Jobs.finish_job(ctx.runner, job.id, %{
          "status" => "succeeded",
          "structured_output" => @analysis_output
        })

      task = Tasks.get_task!(ctx.workspace, task.id)
      assert %Task{status: :running} = task
      assert task.decision_questionnaire == nil
      assert task.decision_analysis_job_id == nil
    end

    test "answer/4 keeps the questions and answers and hands them to the next attempt", ctx do
      task = block_with_questions(ctx, create_task(ctx))

      answers = [
        %{"escolhas" => ["Safari 17"], "outro" => nil},
        %{"escolhas" => ["Board", "Decisões"], "outro" => "e o menu"}
      ]

      assert {:ok, %Task{status: :running, current_stage: 0} = task} =
               Tasks.answer(task, answers, "capriche", by: ctx.user)

      assert task.decision_questionnaire == nil

      assert [decision] = Tasks.list_decisions(task)
      assert decision.action == :retry
      assert decision.decided_by_user_id == ctx.user.id
      assert decision.instructions == "capriche"
      assert %{"perguntas" => [_, _]} = decision.questions
      assert %{"respostas" => ^answers} = decision.answers

      assert [_blocked, %StageRun{attempt: 2, answers: run_answers}] = task.stage_runs
      assert %{"perguntas" => [_, _], "respostas" => ^answers} = run_answers

      prompt = current_job(task).prompt
      assert prompt =~ "Respostas da pessoa às suas perguntas"
      assert prompt =~ "Em qual navegador reproduz?"
      assert prompt =~ "Safari 17"
      assert prompt =~ "e o menu"
      assert prompt =~ "capriche"
    end

    test "answers that do not answer every question are refused", ctx do
      task = block_with_questions(ctx, create_task(ctx))

      assert {:error, :invalid_answers, _reason} =
               Tasks.answer(task, [%{"escolhas" => ["Safari 17"], "outro" => nil}], nil, [])

      assert {:error, :invalid_answers, _reason} =
               Tasks.answer(
                 task,
                 [
                   %{"escolhas" => ["Edge"], "outro" => nil},
                   %{"escolhas" => ["Board"], "outro" => nil}
                 ],
                 nil,
                 []
               )

      assert Tasks.list_decisions(task) == []
      assert %Task{status: :awaiting_decision} = Tasks.get_task!(ctx.workspace, task.id)
    end

    test "advance takes partial answers to the next stage", ctx do
      task = block_with_questions(ctx, create_task(ctx))

      answers = [
        %{"escolhas" => ["Safari 17"], "outro" => nil},
        %{"escolhas" => [], "outro" => nil}
      ]

      assert {:ok, %Task{current_stage: 1} = task} =
               Tasks.advance(task, nil, by: ctx.user, answers: answers)

      assert [decision] = Tasks.list_decisions(task)
      assert decision.action == :advance
      assert %{"respostas" => ^answers} = decision.answers
      assert current_job(task).prompt =~ "Safari 17"
    end

    test "a decision twice on the same pause: the second is refused", ctx do
      task = block_with_questions(ctx, create_task(ctx))

      assert {:ok, _} = Tasks.retry_stage(task, nil)
      assert {:error, :not_awaiting} = Tasks.retry_stage(task, nil)

      assert {:error, :not_awaiting} =
               Tasks.answer(
                 task,
                 [
                   %{"escolhas" => ["Safari 17"], "outro" => nil},
                   %{"escolhas" => ["Board"], "outro" => nil}
                 ],
                 nil,
                 []
               )

      assert [_one] = Tasks.list_decisions(task)
    end

    test "the issue comment carries the questions and the answers", ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "delivery" => "pr",
          "stages" => [%{"key" => "a", "name" => "Etapa A", "prompt" => "p"}]
        })

      task =
        create_task(%{ctx | pipeline: pipeline}, %{
          "issue_url" => "https://github.com/acme/app/issues/42"
        })

      task = block_with_questions(ctx, task)

      {:ok, task} =
        Tasks.answer(
          task,
          [
            %{"escolhas" => ["Safari 17"], "outro" => nil},
            %{"escolhas" => ["Board"], "outro" => "e o menu"}
          ],
          nil,
          by: ctx.user
        )

      comment = current_job(task).context["delivery"]["issue_comment"]["body"]
      assert comment =~ "Em qual navegador reproduz?"
      assert comment =~ "Safari 17"
      assert comment =~ "Quais telas mudam?"
      assert comment =~ "e o menu"
    end
  end

  describe "delivery (git and GitHub)" do
    setup ctx do
      %{pipeline: pipeline_fixture(ctx.workspace, %{"name" => "Com PR", "delivery" => "pr"})}
    end

    test "each stage commits and updates the draft PR; the last one marks it ready", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      issue = "https://github.com/acme/app/issues/42"
      task = create_task(ctx, %{"issue_url" => issue})
      assert task.issue_url == issue

      assert_receive {:job_assign, first}

      assert %{
               "commit_message" => "Etapa A: Corrigir o login",
               "push" => true,
               "pr" => %{"title" => "Corrigir o login", "body" => body, "ready" => false}
             } = first.context["delivery"]

      assert body =~ "Closes #{issue}"
      assert body =~ "O botão de login não responde"
      assert body =~ "- [ ] Etapa A"

      task =
        run_current(ctx, task, %{
          "delivery" => %{
            "commit" => "abc123",
            "pushed" => true,
            "pr_url" => "https://github.com/acme/app/pull/7"
          }
        })

      assert task.pr_url == "https://github.com/acme/app/pull/7"

      assert [%Task{pr_url: "https://github.com/acme/app/pull/7"}] =
               Tasks.list_with_pull_request(ctx.workspace)

      assert_receive {:job_assign, second}
      assert second.context["delivery"]["pr"]["ready"] == true
      # The last stage's delivery marks the PR ready: every stage is checked.
      refute second.context["delivery"]["pr"]["body"] =~ "- [ ]"
      assert second.context["delivery"]["pr"]["body"] =~ "- [x] Etapa A"
    end

    test "a decision is commented on the issue with the next stage", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx, %{"issue_url" => "https://github.com/acme/app/issues/42"})
      assert_receive {:job_assign, _first}

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "Qual navegador?"}
        })

      {:ok, task} = Tasks.retry_stage(task, "No Safari", by: ctx.user)
      again = current_job(task)

      assert %{"url" => "https://github.com/acme/app/issues/42", "body" => comment} =
               again.context["delivery"]["issue_comment"]

      assert comment =~ "Qual navegador?"
      assert comment =~ "No Safari"
    end

    test "nothing to deliver for a pipeline without delivery or a directory without git", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      create_task(ctx, %{"directory" => "notas"})
      assert_receive {:job_assign, job}
      refute Map.has_key?(job.context, "delivery")
    end

    test "the issue must be a GitHub issue URL", ctx do
      assert {:error, changeset} =
               Tasks.create_task(ctx.user, ctx.workspace, %{
                 "title" => "T",
                 "prompt" => "p",
                 "pipeline_id" => ctx.pipeline.id,
                 "runner_id" => ctx.runner.id,
                 "directory" => "app",
                 "issue_url" => "https://exemplo.com/x"
               })

      assert %{issue_url: [_]} = errors_on(changeset)
    end
  end

  describe "a task from a GitHub issue" do
    test "takes the issue's title, text and link, with the project's pipeline and directory",
         ctx do
      {:ok, project} =
        PipeMaestro.Projects.create_project(
          ctx.workspace,
          %{
            "name" => "App",
            "directory" => "app",
            "github_repo" => "acme/app",
            "trigger_label" => "claude",
            "trigger_pipeline_id" => ctx.pipeline.id
          },
          ctx.user
        )

      issue = %{
        "title" => "Botão quebrado",
        "body" => "Ao clicar nada acontece.",
        "html_url" => "https://github.com/acme/app/issues/9"
      }

      assert {:ok, task} = Tasks.create_from_issue(ctx.workspace, project, issue, ctx.runner.id)
      assert task.title == "Botão quebrado"
      assert task.prompt =~ "Ao clicar nada acontece."
      assert task.issue_url == "https://github.com/acme/app/issues/9"
      assert task.directory == "app"
      assert task.pipeline_id == ctx.pipeline.id
      assert task.created_by_user_id == ctx.user.id

      empty = %{issue | "body" => nil, "html_url" => "https://github.com/acme/app/issues/10"}
      assert {:ok, task} = Tasks.create_from_issue(ctx.workspace, project, empty, ctx.runner.id)
      assert task.prompt =~ "Botão quebrado"
    end
  end

  describe "stages in parallel" do
    setup ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{"key" => "impl", "name" => "Implementar", "prompt" => "p"},
            %{
              "key" => "seg",
              "name" => "Auditoria de segurança",
              "prompt" => "p",
              "group" => "auditorias"
            },
            %{
              "key" => "perf",
              "name" => "Auditoria de desempenho",
              "prompt" => "p",
              "group" => "auditorias"
            },
            %{"key" => "fim", "name" => "Consolidar", "prompt" => "p"}
          ]
        })

      %{pipeline: pipeline}
    end

    defp run_stage(ctx, task, key, report) do
      task = Tasks.get_task!(ctx.workspace, task.id)
      run = Enum.find(task.stage_runs, &(&1.key == key and &1.status == :running))
      {:ok, _} = Jobs.mark_started(ctx.runner, run.job.id)

      payload =
        Map.merge(
          %{
            "status" => "succeeded",
            "exit_code" => 0,
            "structured_output" => %{"status" => "ok", "resumo" => "feito"},
            "artifact" => "# Artefato"
          },
          report
        )

      {:ok, _} = Jobs.finish_job(ctx.runner, run.job.id, payload)
      Tasks.get_task!(ctx.workspace, task.id)
    end

    test "a group of stages runs at once and the task goes on when all of them pass", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      task = create_task(ctx)
      assert_receive {:job_assign, _impl}
      task = run_stage(ctx, task, "impl", %{})

      assert_receive {:job_assign, a}
      assert_receive {:job_assign, b}
      assert Enum.sort([a.context["parallel"], b.context["parallel"]]) == [true, true]
      # Each reads what came before the group, not its sibling's artifact.
      refute a.prompt =~ "02-seg.md\n- Auditoria"
      assert a.prompt =~ "01-impl.md"
      assert %Task{current_stage: 1, status: :running} = task

      task = run_stage(ctx, task, "seg", %{})
      assert %Task{current_stage: 1, status: :running} = task
      refute_receive {:job_assign, _}

      task = run_stage(ctx, task, "perf", %{})
      assert %Task{current_stage: 3, status: :running} = task
      assert_receive {:job_assign, last}
      assert last.prompt =~ "02-seg.md"
      assert last.prompt =~ "03-perf.md"
    end

    test "a stage of the group that blocks pauses the task once the others end; retry redoes it",
         ctx do
      task = create_task(ctx)
      task = run_stage(ctx, task, "impl", %{})

      task =
        run_stage(ctx, task, "seg", %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "Falta acesso"}
        })

      assert %Task{status: :running} = task

      task = run_stage(ctx, task, "perf", %{})
      assert %Task{status: :awaiting_decision, decision_reason: reason} = task
      assert reason =~ "Auditoria de segurança"
      assert reason =~ "Falta acesso"

      {:ok, task} = Tasks.retry_stage(task, "Use o token")
      running = Enum.filter(task.stage_runs, &(&1.status == :running))
      assert Enum.map(running, & &1.key) == ["seg"]

      task = run_stage(ctx, task, "seg", %{})
      assert %Task{current_stage: 3} = task
    end

    test "the questions of the group's blocked stages are put together", ctx do
      question = fn title ->
        %{
          "titulo" => title,
          "pergunta" => "Qual caminho em #{title}?",
          "multipla" => false,
          "opcoes" => [
            %{"rotulo" => "Sim", "descricao" => "", "recomendada" => true},
            %{"rotulo" => "Não", "descricao" => "", "recomendada" => false}
          ]
        }
      end

      blocked = fn title ->
        %{
          "structured_output" => %{
            "status" => "bloqueado",
            "resumo" => "dúvida",
            "perguntas" => [question.(title)]
          }
        }
      end

      task = create_task(ctx)
      task = run_stage(ctx, task, "impl", %{})
      task = run_stage(ctx, task, "seg", blocked.("Segurança"))
      task = run_stage(ctx, task, "perf", blocked.("Desempenho"))

      assert %Task{status: :awaiting_decision} = task
      assert %{"origem" => "agente", "perguntas" => questions} = task.decision_questionnaire
      # The stage's name goes on screen only, never into the data.
      assert Enum.map(questions, & &1["titulo"]) == ["Segurança", "Desempenho"]
      assert task.decision_analysis_job_id == nil
    end

    test "the first stage cannot be in a group", ctx do
      assert {:error, changeset} =
               Pipelines.create_pipeline(ctx.workspace, %{
                 "name" => "Ruim",
                 "stages" => [
                   %{"name" => "A", "prompt" => "p", "group" => "g"},
                   %{"name" => "B", "prompt" => "p", "group" => "g"}
                 ]
               })

      assert %{stages: [_]} = errors_on(changeset)
    end
  end

  describe "the task's budget" do
    test "alerts: tasks whose runner is offline and tasks near their budget", ctx do
      pipeline = pipeline_fixture(ctx.workspace, %{"max_task_cost_usd" => "1"})
      task = create_task(ctx, %{"pipeline_id" => pipeline.id})
      task = run_current(ctx, task, %{"cost_usd" => 0.85})

      assert [{:runner_offline, %Task{id: id}}, {:near_budget, %Task{id: id}, spent, "1"}] =
               Tasks.alerts(ctx.workspace, MapSet.new())

      assert id == task.id
      assert Decimal.equal?(spent, Decimal.new("0.85"))
      assert [{:near_budget, _, _, _}] = Tasks.alerts(ctx.workspace, MapSet.new([ctx.runner.id]))

      {:ok, _} =
        PipeMaestro.Runners.record_rate_limit(ctx.runner, %{
          "status" => "allowed_warning",
          "utilization" => %{"five_hour" => 0.9}
        })

      assert [{:near_budget, _, _, _}, {:runner_near_limit, %Task{id: ^id}, _runner}] =
               Tasks.alerts(ctx.workspace, MapSet.new([ctx.runner.id]))

      {:ok, _} = Tasks.cancel_task(task)
      assert Tasks.alerts(ctx.workspace, MapSet.new()) == []
    end

    test "runner_offline?: a running task whose runner is not online", ctx do
      task = create_task(ctx)

      assert Tasks.runner_offline?(task, MapSet.new())
      refute Tasks.runner_offline?(task, MapSet.new([ctx.runner.id]))

      paused =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "?"}
        })

      assert paused.status == :awaiting_decision
      refute Tasks.runner_offline?(paused, MapSet.new())
    end

    test "alerts_change_at: the earliest future reset of a runner near its limit", ctx do
      now = ~U[2026-11-04 12:00:00Z]
      task = create_task(ctx)

      near = fn resets_at ->
        %PipeMaestro.Runners.Runner{
          rate_limit: %{
            "status" => "allowed_warning",
            "utilization" => %{"five_hour" => 0.9},
            "resets_at" => resets_at
          }
        }
      end

      assert Tasks.alerts_change_at([], now) == nil
      assert Tasks.alerts_change_at([{:runner_offline, task}], now) == nil

      later = DateTime.to_unix(~U[2026-11-04 15:00:00Z])
      sooner = DateTime.to_iso8601(~U[2026-11-04 13:00:00Z])
      past = DateTime.to_unix(~U[2026-11-04 11:00:00Z])

      alerts = [
        {:runner_near_limit, task, near.(later)},
        {:runner_offline, task},
        {:runner_near_limit, task, near.(sooner)},
        {:runner_near_limit, task, near.(past)},
        {:runner_near_limit, task, near.(nil)}
      ]

      assert Tasks.alerts_change_at(alerts, now) == ~U[2026-11-04 13:00:00Z]

      assert Tasks.alerts_change_at(
               [{:runner_near_limit, task, near.(past)}, {:runner_near_limit, task, near.(nil)}],
               now
             ) == nil
    end

    test "past the pipeline's cap per task, the task pauses instead of going on", ctx do
      pipeline = pipeline_fixture(ctx.workspace, %{"max_task_cost_usd" => "0.5"})
      task = create_task(ctx, %{"pipeline_id" => pipeline.id})

      task = run_current(ctx, task, %{"cost_usd" => 0.3})
      assert %Task{status: :running, current_stage: 1} = task
      assert Decimal.equal?(Tasks.cost(task), Decimal.new("0.3"))
      assert %{} = costs = Tasks.costs([task.id, Ecto.UUID.generate()])
      assert Decimal.equal?(costs[task.id], Decimal.new("0.3"))
      assert map_size(costs) == 1

      task = run_current(ctx, task, %{"cost_usd" => 0.3, "status" => "failed", "exit_code" => 1})
      assert %Task{status: :awaiting_decision, decision_reason: reason} = task
      assert reason =~ "orçamento"
      assert reason =~ "US$ 0.6"

      assert {:ok, %Task{status: :running}} = Tasks.retry_stage(task, nil)
    end

    test "without a cap the task goes on", ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{"cost_usd" => 99.0})
      assert %Task{status: :running, current_stage: 1} = task
    end
  end

  describe "who decides, and by when" do
    test "a paused task's decision goes to its creator, due in a day, and can be passed on",
         ctx do
      task = create_task(ctx)
      blocked = %{"structured_output" => %{"status" => "bloqueado", "resumo" => "?"}}
      task = run_current(ctx, task, blocked)

      assert task.decision_owner_id == ctx.user.id
      assert DateTime.diff(task.decision_due_at, DateTime.utc_now(), :hour) in 23..24

      colleague = member_fixture(ctx.workspace)
      assert {:ok, %Task{decision_owner_id: id}} = Tasks.assign_decision(task, colleague)
      assert id == colleague.id
      assert [%Task{decision_owner: %{id: ^id}}] = Tasks.list_awaiting(ctx.workspace)
      assert {:error, :not_a_member} = Tasks.assign_decision(task, user_fixture())

      {:ok, task} = Tasks.retry_stage(task, nil)
      assert %Task{decision_owner_id: nil, decision_due_at: nil} = task
    end

    test "an overdue decision is an alert", ctx do
      task = create_task(ctx)

      task =
        run_current(ctx, task, %{
          "structured_output" => %{"status" => "bloqueado", "resumo" => "?"}
        })

      task
      |> Ecto.Changeset.change(decision_due_at: DateTime.add(DateTime.utc_now(:second), -60))
      |> PipeMaestro.Repo.update!()

      assert [{:decision_overdue, %Task{id: id}}] =
               Tasks.alerts(ctx.workspace, MapSet.new([ctx.runner.id]))

      assert id == task.id
    end
  end

  describe "the workspace's limit of tasks at once" do
    setup ctx do
      {:ok, workspace} =
        PipeMaestro.Workspaces.update_workspace(ctx.workspace, %{"max_running_tasks" => 1})

      %{workspace: workspace}
    end

    test "past it a task waits in line, and starts when one stops running", ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})
      first = create_task(ctx)
      assert_receive {:job_assign, _job}

      second = create_task(ctx, %{"title" => "Segunda"})
      assert %Task{status: :queued, stage_runs: []} = second
      refute_receive {:job_assign, _job}

      blocked = %{"structured_output" => %{"status" => "bloqueado", "resumo" => "?"}}
      run_current(ctx, first, blocked)

      assert %Task{status: :running, current_stage: 0} = Tasks.get_task!(ctx.workspace, second.id)
      assert_receive {:job_assign, job}
      assert job.prompt =~ "Segunda"
    end

    test "a task in line can be canceled", ctx do
      create_task(ctx)
      queued = create_task(ctx, %{"title" => "Segunda"})
      assert {:ok, %Task{status: :canceled}} = Tasks.cancel_task(queued)
    end
  end

  describe "talking to a running task" do
    test "an instruction waits for the next stage, then goes with it", ctx do
      task = create_task(ctx)

      assert {:ok, %Task{pending_instructions: "use o Safari"}} =
               Tasks.instruct(task, " use o Safari ")

      assert {:ok, %Task{pending_instructions: "use o Safari\n\ne o Chrome"}} =
               Tasks.instruct(task, "e o Chrome")

      assert Tasks.instruct(task, "  ") == {:error, :blank}

      task = run_current(ctx, task, %{})
      assert %Task{current_stage: 1, pending_instructions: nil} = task
      assert List.last(task.stage_runs).instructions == "use o Safari\n\ne o Chrome"
      assert current_job(task).prompt =~ "e o Chrome"
    end

    test "pause after this stage, even one that does not ask for it", ctx do
      task = create_task(ctx)
      assert {:ok, %Task{pause_requested: true}} = Tasks.request_pause(task)

      task = run_current(ctx, task, %{})

      assert %Task{status: :awaiting_decision, pause_requested: false, decision_reason: reason} =
               task

      assert reason =~ "pediu uma pausa"
    end

    test "redo from an earlier stage: it and the ones after run again", ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{})
      task = run_current(ctx, task, %{})
      assert task.status == :succeeded

      assert {:ok, %Task{status: :running, current_stage: 0} = task} =
               Tasks.redo_from(task, 0, "refaça com testes")

      assert Enum.map(task.stage_runs, &{&1.index, &1.attempt}) == [{0, 1}, {0, 2}, {1, 1}]
      assert Enum.at(task.stage_runs, 1).instructions == "refaça com testes"

      task = run_current(ctx, task, %{})
      assert %Task{current_stage: 1} = task

      assert Enum.map(task.stage_runs, &{&1.index, &1.attempt}) == [
               {0, 1},
               {0, 2},
               {1, 1},
               {1, 2}
             ]
    end

    test "only a task that is not running can be redone, and not without its worktree", ctx do
      task = create_task(ctx)
      assert Tasks.redo_from(task, 0, nil) == {:error, :running}

      {:ok, task} = Tasks.cancel_task(task)

      task =
        task
        |> Ecto.Changeset.change(worktree_removed_at: DateTime.utc_now(:second))
        |> PipeMaestro.Repo.update!()

      assert Tasks.redo_from(task, 0, nil) == {:error, :no_worktree}
    end
  end

  test "canceling a running task cancels its job", ctx do
    task = create_task(ctx)

    assert {:ok, %Task{status: :canceled}} = Tasks.cancel_task(task)
    assert current_job(task).status == :canceled
  end

  describe "the board" do
    test "filters by pipeline, runner, directory and person", ctx do
      other_pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Outro"})
      colleague = member_fixture(ctx.workspace)
      a = create_task(ctx)
      b = create_task(ctx, %{"directory" => "notas", "pipeline_id" => other_pipeline.id})

      {:ok, c} =
        Tasks.create_task(colleague, ctx.workspace, %{
          "title" => "De outra pessoa",
          "prompt" => "x",
          "pipeline_id" => ctx.pipeline.id,
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })

      ids = fn filters ->
        ctx.workspace |> Tasks.list_tasks(filters) |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert ids.(%{}) == Enum.sort([a.id, b.id, c.id])
      assert ids.(%{"pipeline" => "Outro"}) == [b.id]
      assert ids.(%{"directory" => "notas"}) == [b.id]
      assert ids.(%{"user_id" => colleague.id}) == [c.id]

      assert ids.(%{"runner_id" => ctx.runner.id, "directory" => "app"}) ==
               Enum.sort([a.id, c.id])

      assert ids.(%{"pipeline" => "", "runner_id" => ""}) == Enum.sort([a.id, b.id, c.id])
    end

    test "searches titles and prompts", ctx do
      a = create_task(ctx, %{"title" => "Corrigir login", "prompt" => "O botão não responde"})
      b = create_task(ctx, %{"title" => "Rodapé", "prompt" => "Ajustar o LOGIN social"})
      _c = create_task(ctx, %{"title" => "Outra", "prompt" => "nada a ver"})

      ids = fn q ->
        ctx.workspace |> Tasks.list_tasks(%{"q" => q}) |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert ids.("login") == Enum.sort([a.id, b.id])
      assert ids.("botão") == [a.id]
      assert ids.("100%_") == []
    end

    test "runs a task again: same request, pipeline, runner and directory", ctx do
      task = create_task(ctx)
      {:ok, _} = Tasks.cancel_task(task)
      colleague = member_fixture(ctx.workspace)

      assert {:ok, again} = Tasks.rerun(colleague, Tasks.get_task!(ctx.workspace, task.id))
      assert again.id != task.id

      assert {again.title, again.prompt, again.directory} ==
               {task.title, task.prompt, task.directory}

      assert again.pipeline_id == task.pipeline_id
      assert again.runner_id == task.runner_id
      assert again.created_by_user_id == colleague.id
      assert again.status == :running

      assert Tasks.duplicate_params(task) == %{
               "title" => task.title,
               "prompt" => task.prompt,
               "pipeline_id" => task.pipeline_id,
               "runner_id" => task.runner_id,
               "directory" => task.directory
             }
    end

    test "counts the decisions waiting and tells who listens", ctx do
      assert Tasks.count_awaiting(ctx.workspace) == 0
      :ok = Tasks.subscribe({:decisions, ctx.workspace.id})

      task = create_task(ctx)
      blocked = %{"structured_output" => %{"status" => "bloqueado", "resumo" => "dúvida"}}
      task = run_current(ctx, task, blocked)

      assert_receive {:pending_decisions, 1}
      assert Tasks.count_awaiting(ctx.workspace) == 1
      assert [%Task{id: id, runner: %{}}] = Tasks.list_awaiting(ctx.workspace)
      assert id == task.id

      {:ok, _task} = Tasks.cancel_task(task)
      assert_receive {:pending_decisions, 0}
    end

    test "tells the workspace when a task pauses or ends", ctx do
      :ok = Tasks.subscribe({:events, ctx.workspace.id})
      task = create_task(ctx)
      task_id = task.id

      blocked = %{"structured_output" => %{"status" => "bloqueado", "resumo" => "dúvida"}}
      task = run_current(ctx, task, blocked)
      assert_receive {:task_event, %{id: ^task_id, kind: :awaiting, title: "Corrigir o login"}}

      {:ok, _} = Tasks.advance(task, nil)
      task = run_current(ctx, Tasks.get_task!(ctx.workspace, task_id), %{})
      assert task.status == :succeeded
      assert_receive {:task_event, %{id: ^task_id, kind: :succeeded}}
    end

    test "sums up a period: tasks by state and what the stages cost", ctx do
      task = create_task(ctx)
      run_current(ctx, task, %{"cost_usd" => 0.25})
      run_current(ctx, task, %{"cost_usd" => 0.5})
      create_task(ctx)

      since = DateTime.add(DateTime.utc_now(), -7, :day)
      stats = Tasks.stats(ctx.workspace, since)

      assert stats.running == 1
      assert stats.succeeded == 1
      assert stats.awaiting == 0
      assert stats.failed == 0
      assert Decimal.equal?(stats.cost_usd, Decimal.new("0.75"))

      assert Tasks.stats(workspace_fixture(), since).succeeded == 0
    end
  end

  describe "removing the worktree" do
    setup ctx do
      task = create_task(ctx)
      task = run_current(ctx, task, %{"workdir" => "/w/worktrees/x"})
      %{task: task}
    end

    test "only once the task ended, telling the runner", ctx do
      assert Tasks.remove_worktree(ctx.task) == {:error, :active}

      {:ok, task} = Tasks.cancel_task(ctx.task)
      task = Tasks.get_task!(ctx.workspace, task.id)
      :ok = Jobs.subscribe({:runner, ctx.runner.id})

      assert {:ok, %Task{worktree_removal_requested_at: %DateTime{}} = task} =
               Tasks.remove_worktree(task)

      assert_receive {:worktree_remove, %{"task_id" => task_id, "directory" => "app"}}
      assert task_id == task.id
      assert [%Task{id: ^task_id}] = Tasks.pending_worktree_removals(ctx.runner)

      assert {:ok, %Task{worktree_removed_at: %DateTime{}}} =
               Tasks.worktree_removed(ctx.runner, task.id, nil)

      assert Tasks.pending_worktree_removals(ctx.runner) == []
      task = Tasks.get_task!(ctx.workspace, task.id)
      assert Tasks.remove_worktree(task) == {:error, :no_worktree}
    end

    test "a failed removal keeps the error and can be asked again", ctx do
      {:ok, task} = Tasks.cancel_task(ctx.task)
      {:ok, task} = Tasks.remove_worktree(task)

      assert {:ok, %Task{worktree_error: "ocupado", worktree_removal_requested_at: nil} = task} =
               Tasks.worktree_removed(ctx.runner, task.id, "ocupado")

      assert Tasks.pending_worktree_removals(ctx.runner) == []
      assert {:ok, %Task{worktree_error: nil}} = Tasks.remove_worktree(task)
    end

    test "a task with no worktree has nothing to remove", ctx do
      task = create_task(ctx, %{"directory" => "notas"})
      {:ok, task} = Tasks.cancel_task(task)
      assert Tasks.remove_worktree(task) == {:error, :no_worktree}
    end

    test "only the task's runner reports the removal", ctx do
      {:ok, task} = Tasks.cancel_task(ctx.task)
      {:ok, _task} = Tasks.remove_worktree(task)
      {other, _token} = runner_fixture(ctx.workspace, ctx.user)
      assert Tasks.worktree_removed(other, task.id, nil) == {:error, :not_found}
      assert Tasks.worktree_removed(ctx.runner, "nada", nil) == {:error, :not_found}
    end
  end

  test "a workspace does not see another's tasks", ctx do
    task = create_task(ctx)
    other = workspace_fixture()

    assert Tasks.list_tasks(other) == []
    assert_raise Ecto.NoResultsError, fn -> Tasks.get_task!(other, task.id) end
  end
end
