defmodule PipeMaestro.ProposalsTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, Pipelines, Projects, Proposals, Runners, Tasks}
  alias PipeMaestro.Proposals.ImproveKind
  alias PipeMaestroProtocol.Job, as: WireJob

  @directories [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}]

  @pipeline_output %{
    "analise" => "Um app Phoenix. Testes com `mix test`.",
    "verificacoes" => [
      %{"comando" => "mix test", "passou" => true},
      %{"comando" => "mix credo", "passou" => false, "observacao" => "2 avisos"}
    ],
    "projeto" => %{
      "nome" => "App",
      "setup" => "mix deps.get",
      "teste" => "mix test",
      "lint" => "mix credo --strict",
      "copy_paths" => ["deps", "_build"],
      "notas" => "Use `make ci`."
    },
    "pipeline" => %{
      "name" => "Entrega do App",
      "delivery" => "pr",
      "stages" => [
        %{"key" => "plano", "name" => "Plano", "prompt" => "Planeje: {{tarefa.descricao}}"},
        %{
          "key" => "codigo",
          "name" => "Código",
          "prompt" => "Implemente o plano.",
          "gates" => ["{{projeto.teste}}"],
          "rules" => ["status == bloqueado"]
        }
      ]
    }
  }

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user)

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{directories: @directories, capabilities: ["scratch"]})
      )

    %{workspace: workspace, user: user, runner: runner}
  end

  defp ask(ctx, kind, attrs, previous \\ nil) do
    base = %{"runner_id" => ctx.runner.id, "directory" => "app"}
    Proposals.request(kind, ctx.user, ctx.workspace, Map.merge(base, attrs), previous)
  end

  defp finish(ctx, job, attrs) do
    {:ok, _started} = Jobs.mark_started(ctx.runner, job.id)
    {:ok, job} = Jobs.finish_job(ctx.runner, job.id, attrs)
    job
  end

  defp succeed(ctx, job, output),
    do: finish(ctx, job, %{"status" => "succeeded", "structured_output" => output})

  # What reaches the runner: a valid job, without the proposal marker.
  defp wire!(job) do
    {:ok, wire} = WireJob.new(Map.merge(job.context, %{"id" => job.id, "prompt" => job.prompt}))
    refute Map.has_key?(WireJob.to_map(wire), "proposal")
    wire
  end

  describe "the shared mechanism" do
    test "a directory is studied in a disposable worktree, only by a capable runner", ctx do
      assert {:ok, job} = ask(ctx, "pipeline", %{"request" => "PRs"})
      assert %WireJob{scratch: true, directory: "app"} = wire!(job)
      assert Proposals.kind(job) == "pipeline"
      assert Proposals.input(job) == %{"directory" => "app", "request" => "PRs"}
      assert Proposals.title(job) == "PRs"
      assert [listed] = Proposals.list_recent(ctx.workspace)
      assert listed.id == job.id
      assert Proposals.list_recent(ctx.workspace, ["task"]) == []
      assert Proposals.get_proposal!(ctx.workspace, job.id).id == job.id

      assert {:error, changeset} =
               ask(ctx, "pipeline", %{"directory" => "notas", "request" => "x"})

      assert "precisa ser um repositório git do runner" in errors_on(changeset).directory

      {:ok, _old} = Runners.record_hello(ctx.runner, hello_fixture(%{directories: @directories}))
      assert {:error, changeset} = ask(ctx, "pipeline", %{"request" => "x"})
      assert "atualize este runner para gerar propostas" in errors_on(changeset).runner_id

      assert {:error, changeset} =
               ask(ctx, "pipeline", %{"runner_id" => Ecto.UUID.generate(), "request" => "x"})

      assert errors_on(changeset).runner_id != []
    end

    test "a failed or empty proposal says why", ctx do
      {:ok, job} = ask(ctx, "pipeline", %{"request" => "x"})
      failed = finish(ctx, job, %{"status" => "failed", "error" => "sem créditos"})
      assert Proposals.result(failed) == {:error, "sem créditos"}

      {:ok, job} = ask(ctx, "pipeline", %{"request" => "x"})
      none = finish(ctx, job, %{"status" => "succeeded"})
      assert {:error, "O agente terminou sem" <> _} = Proposals.result(none)
    end

    test "a job that is not a proposal is not found as one", ctx do
      {:ok, job} =
        Jobs.create_job(ctx.user, ctx.workspace, %{prompt: "x", runner_id: ctx.runner.id})

      refute Proposals.proposal?(job)
      assert_raise Ecto.NoResultsError, fn -> Proposals.get_proposal!(ctx.workspace, job.id) end
    end
  end

  describe "pipeline" do
    test "asks for a pipeline and reads it into the forms' attributes", ctx do
      assert {:ok, job} = ask(ctx, "pipeline", %{"request" => "Um pipeline de entrega com PR"})
      assert job.prompt =~ "diretório `app`"
      assert job.context["output_schema"]["x-pipemaestro-kind"] == "pipeline"
      assert job.context["system_prompt"] =~ "worktree descartável"
      assert job.context["system_prompt"] =~ "{{projeto.teste}}"

      assert {:ok, result} = Proposals.result(succeed(ctx, job, @pipeline_output))
      assert result.analysis =~ "Phoenix"

      assert [%{command: "mix test", passed: true}, %{passed: false, note: "2 avisos"}] =
               result.checks

      assert result.project["copy_paths_text"] == "deps\n_build"
      assert {:ok, project} = Projects.create_project(ctx.workspace, result.project, ctx.user)
      assert project.test_command == "mix test"
      assert {:ok, pipeline} = Pipelines.create_pipeline(ctx.workspace, result.pipeline)
      assert length(pipeline.stages) == 2
    end

    test "a new round carries the last proposal, and a comment even without one", ctx do
      {:ok, first} = ask(ctx, "pipeline", %{"request" => "PRs"})
      first = succeed(ctx, first, @pipeline_output)
      {:ok, second} = ask(ctx, "pipeline", %{"request" => "PRs", "feedback" => "Junte"}, first)
      assert second.prompt =~ "Sua proposta anterior"
      assert second.prompt =~ "Entrega do App"
      assert second.prompt =~ "Junte"

      failed = finish(ctx, second, %{"status" => "failed", "error" => "x"})
      {:ok, third} = ask(ctx, "pipeline", %{"request" => "PRs", "feedback" => "Só 2"}, failed)
      refute third.prompt =~ "Sua proposta anterior"
      assert third.prompt =~ "Só 2"
    end

    test "an incomplete answer is refused", ctx do
      {:ok, job} = ask(ctx, "pipeline", %{"request" => "x"})

      assert {:error, "O agente não devolveu" <> _} =
               Proposals.result(succeed(ctx, job, %{"analise" => "x"}))
    end
  end

  describe "task" do
    test "writes a task from an idea, naming one of the workspace's pipelines", ctx do
      pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})

      assert {:ok, job} =
               ask(ctx, "task", %{
                 "request" => "O login trava às vezes\ncom muitos usuários",
                 "issue_url" => "https://github.com/acme/app/issues/7"
               })

      assert %WireJob{scratch: true} = wire!(job)
      assert Proposals.title(job) == "O login trava às vezes"
      assert job.prompt =~ "**Correção de bug**"
      assert job.prompt =~ "issues/7"
      assert job.context["output_schema"]["x-pipemaestro-kind"] == "task"

      output = %{
        "analise" => "O lock em `Auth` não tem timeout.",
        "titulo" => "Destravar o login sob carga",
        "descricao" => "## Problema\n\nO `Auth.login/2` espera um lock sem timeout.",
        "pipeline" => "correção de bug",
        "pronta" => false,
        "perguntas" => ["Qual o timeout aceitável?"]
      }

      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      assert result.title == "Destravar o login sob carga"
      assert result.pipeline.id == pipeline.id
      refute result.ready
      assert result.questions == ["Qual o timeout aceitável?"]

      assert result.task_params == %{
               "title" => "Destravar o login sob carga",
               "prompt" => output["descricao"],
               "pipeline_id" => pipeline.id,
               "runner_id" => ctx.runner.id,
               "directory" => "app",
               "issue_url" => "https://github.com/acme/app/issues/7"
             }

      assert {:ok, _task} = Tasks.create_task(ctx.user, ctx.workspace, result.task_params)
    end

    test "refuses a request without an idea or with a bad issue link", ctx do
      assert {:error, changeset} = ask(ctx, "task", %{"request" => ""})
      assert "conte a ideia da tarefa" in errors_on(changeset).request

      assert {:error, changeset} = ask(ctx, "task", %{"request" => "x", "issue_url" => "nope"})
      assert errors_on(changeset).issue_url != []
    end

    test "knows when an issue is being triaged", ctx do
      url = "https://github.com/acme/app/issues/9"
      refute Proposals.triaging?(ctx.workspace, url)
      {:ok, job} = ask(ctx, "task", %{"request" => "x", "issue_url" => url})
      assert Proposals.triaging?(ctx.workspace, url)
      succeed(ctx, job, %{})
      refute Proposals.triaging?(ctx.workspace, url)
    end

    test "triages an issue once, with its body cut, on behalf of who set the trigger up", ctx do
      pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})

      {:ok, project} =
        Projects.create_project(
          ctx.workspace,
          %{
            "name" => "App",
            "directory" => "app",
            "copy_paths_text" => "deps\nvendor",
            "github_repo" => "acme/app",
            "trigger_label" => "ia",
            "trigger_pipeline_id" => pipeline.id,
            "trigger_mode" => "triage"
          },
          ctx.user
        )

      issue = %{
        "title" => "Botão quebrado",
        "body" => String.duplicate("a", 40_000),
        "html_url" => "https://github.com/acme/app/issues/5"
      }

      assert {:ok, job} = Proposals.triage_issue(ctx.workspace, project, issue, ctx.runner.id)
      assert job.created_by_user_id == ctx.user.id
      assert job.prompt =~ "prefira-o"
      assert byte_size(job.prompt) < 20_000
      # The project's own dependency paths go to the disposable worktree.
      assert job.context["setup"] == %{"copy" => ["deps", "vendor"]}

      assert Proposals.triage_issue(ctx.workspace, project, issue, ctx.runner.id) ==
               {:error, :already_triaging}
    end

    test "an answer without a title or description is refused", ctx do
      {:ok, job} = ask(ctx, "task", %{"request" => "x"})

      assert {:error, _} =
               Proposals.result(succeed(ctx, job, %{"titulo" => "", "descricao" => "x"}))
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

      task = Tasks.get_task!(ctx.workspace, task.id)
      stage_job = hd(task.stage_runs).job
      {:ok, _} = Jobs.mark_started(ctx.runner, stage_job.id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, stage_job.id, %{
          "status" => "succeeded",
          "structured_output" => %{
            "status" => "bloqueado",
            "resumo" => "Qual navegador?",
            "opcoes" => ["Chrome", "Safari"]
          },
          "artifact" => "# O que tentei",
          "changes" => %{"patch" => "diff --git a/login.ex b/login.ex\n+timeout"},
          "gates" => [
            %{
              "command" => "mix test",
              "expect" => "pass",
              "passed" => false,
              "exit_code" => 1,
              "output" => "1 failure"
            }
          ]
        })

      %{task: Tasks.get_task!(ctx.workspace, task.id)}
    end

    test "asks about a paused task, with what the control plane kept of it", ctx do
      assert ctx.task.status == :awaiting_decision

      assert {:ok, job} =
               Proposals.request("decision", ctx.user, ctx.workspace, %{"task_id" => ctx.task.id})

      assert %WireJob{scratch: true, directory: "app"} = wire!(job)
      assert job.runner_id == ctx.runner.id
      assert Proposals.title(job) == "Corrigir o login"
      assert job.prompt =~ "O botão não responde"
      assert job.prompt =~ "Qual navegador?"
      assert job.prompt =~ "- Chrome"
      assert job.prompt =~ "# O que tentei"
      assert job.prompt =~ "+timeout"
      assert job.prompt =~ "1 failure"

      output = %{
        "diagnostico" => "Falta saber o navegador.",
        "acao" => "retry",
        "escolha" => "Chrome",
        "instrucoes" => "Reproduza no Chrome.",
        "alternativas" => [%{"acao" => "cancel", "motivo" => "Se não reproduzir"}]
      }

      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      assert %{action: "retry", choice: "Chrome", instructions: "Reproduza no Chrome."} = result
      assert result.task_id == ctx.task.id
      assert [%{action: "cancel", reason: "Se não reproduzir"}] = result.alternatives
    end

    test "refuses a task that is not paused or not the workspace's", ctx do
      {:ok, _task} = Tasks.cancel_task(ctx.task, by: ctx.user)

      assert {:error, changeset} =
               Proposals.request("decision", ctx.user, ctx.workspace, %{"task_id" => ctx.task.id})

      assert "a tarefa não está esperando uma decisão" in errors_on(changeset).task_id

      assert {:error, changeset} =
               Proposals.request("decision", ctx.user, ctx.workspace, %{
                 "task_id" => Ecto.UUID.generate()
               })

      assert "não é uma tarefa deste workspace" in errors_on(changeset).task_id
    end

    test "an answer without a known action is refused", ctx do
      {:ok, job} =
        Proposals.request("decision", ctx.user, ctx.workspace, %{"task_id" => ctx.task.id})

      assert {:error, _} = Proposals.result(succeed(ctx, job, %{"acao" => "pular"}))
    end
  end

  describe "improve" do
    setup ctx do
      pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Entrega"})

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "Corrigir o login",
          "prompt" => "x",
          "pipeline_id" => pipeline.id,
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })

      task = Tasks.get_task!(ctx.workspace, task.id)
      first = hd(task.stage_runs).job
      {:ok, _} = Jobs.mark_started(ctx.runner, first.id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, first.id, %{
          "status" => "succeeded",
          "structured_output" => %{"status" => "ok", "resumo" => "feito"},
          "gates" => [
            %{
              "command" => "mix test",
              "expect" => "pass",
              "passed" => false,
              "exit_code" => 1,
              "output" => "x"
            }
          ]
        })

      %{pipeline: pipeline, task: task}
    end

    test "reads the pipeline's history and proposes a revision with notes", ctx do
      {:ok, _project} =
        Projects.create_project(
          ctx.workspace,
          %{"name" => "App", "directory" => "app", "notes" => "Notas velhas"},
          ctx.user
        )

      assert {:ok, job} =
               ask(ctx, "improve", %{"pipeline_id" => ctx.pipeline.id, "focus" => "Custo"})

      assert %WireJob{scratch: true} = wire!(job)
      assert Proposals.title(job) == "Entrega"
      assert job.prompt =~ "Foco pedido pela pessoa"
      assert job.prompt =~ "Notas velhas"
      assert job.prompt =~ "```yaml"
      assert job.context["output_schema"]["x-pipemaestro-kind"] == "improve"

      output = %{
        "analise" => "O gate falha muito.",
        "mudancas" => [%{"onde" => "Etapa A", "o_que" => "gate", "por_que" => "falhou"}],
        "pipeline" => @pipeline_output["pipeline"],
        "notas" => "Notas novas"
      }

      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      assert result.pipeline_id == ctx.pipeline.id
      assert result.notes == "Notas novas"
      assert [%{where: "Etapa A", what: "gate", why: "falhou"}] = result.changes
      assert {:ok, revised} = Pipelines.update_pipeline(ctx.pipeline, result.pipeline)
      assert revised.version == 2
    end

    test "the history digests the finished tasks", ctx do
      assert ImproveKind.history_section(ctx.pipeline) =~ "Nenhuma tarefa concluída"

      {:ok, _canceled} =
        Tasks.cancel_task(Tasks.get_task!(ctx.workspace, ctx.task.id), by: ctx.user)

      digest = ImproveKind.history_section(ctx.pipeline)
      assert digest =~ "### Corrigir o login (canceled)"
      assert digest =~ "gates reprovados: `mix test`"
      assert [%{decisions: _}] = Tasks.history(ctx.pipeline)
    end

    test "refuses another workspace's pipeline", ctx do
      assert {:error, changeset} = ask(ctx, "improve", %{"pipeline_id" => Ecto.UUID.generate()})
      assert "não é um pipeline deste workspace" in errors_on(changeset).pipeline_id
    end
  end
end
