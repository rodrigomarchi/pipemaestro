defmodule PipeMaestro.ProposalsTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Audit, Jobs, Pipelines, Projects, Proposals, Runners, Tasks, Workspaces}
  alias PipeMaestro.Pipelines.{Prompt, Stage}
  alias PipeMaestro.Proposals.{AnalysisKind, ImproveKind, Instructions, PipelineKind, TaskKind}
  alias PipeMaestro.Tasks.Task
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

    %{workspace: workspace, user: user, runner: runner, projects: projects_fixture(runner)}
  end

  # `"directory"` names the project of the runner's directory.
  defp ask(ctx, kind, attrs, previous \\ nil) do
    {directory, attrs} = Map.pop(attrs, "directory", "app")
    base = %{"project_id" => ctx.projects[directory].id}
    Proposals.request(kind, ctx.user, ctx.workspace, Map.merge(base, attrs), previous)
  end

  defp finish(ctx, job, attrs) do
    {:ok, _started} = Jobs.mark_started(ctx.runner, job.id)
    {:ok, job} = Jobs.finish_job(ctx.runner, job.id, attrs)
    job
  end

  defp succeed(ctx, job, output),
    do: finish(ctx, job, %{"status" => "succeeded", "structured_output" => output})

  # Questions as the agent asks them (ADR 0029): the recommended option last,
  # to see it come first, and a title over 12 characters, to see it cut.
  defp structured_questions do
    [
      %{
        "titulo" => "Timeout do login",
        "pergunta" => "Qual o timeout aceitável?",
        "multipla" => false,
        "opcoes" => [
          %{"rotulo" => "30 segundos", "descricao" => "Folgado.", "recomendada" => false},
          %{
            "rotulo" => "5 segundos sob qualquer carga no servidor",
            "descricao" => "O que o produto pede.",
            "recomendada" => true,
            "preview" => "```elixir\n@timeout 5_000\n```"
          }
        ]
      },
      %{
        "titulo" => "Telas",
        "pergunta" => "Quais telas mostram o erro?",
        "multipla" => true,
        "opcoes" => [
          %{"rotulo" => "Login", "descricao" => "A de entrada.", "recomendada" => true},
          %{"rotulo" => "Cadastro", "descricao" => "A de conta nova.", "recomendada" => false}
        ]
      }
    ]
  end

  defp task_output do
    %{
      "analise" => "O lock em `Auth` não tem timeout.",
      "titulo" => "Destravar o login sob carga",
      "descricao" => "## Problema\n\nO `Auth.login/2` espera um lock sem timeout.",
      "pipeline" => "correção de bug",
      "pronta" => true,
      "perguntas" => ["Qual o timeout aceitável?"]
    }
  end

  # What reaches the runner: a valid job, without the proposal marker.
  defp wire!(job) do
    {:ok, wire} = WireJob.new(Map.merge(job.context, %{"id" => job.id, "prompt" => job.prompt}))
    refute Map.has_key?(WireJob.to_map(wire), "proposal")
    wire
  end

  # A proposal runs until the agent is done: no cost cap reaches the runner.
  defp refute_budget(job) do
    refute Map.has_key?(job.context, "max_budget_usd")
    assert %WireJob{max_budget_usd: nil} = wire!(job)
  end

  # Words that would have the agent propose, discuss or keep a cost cap.
  defp refute_caps(text) do
    assert Regex.scan(~r/orçamento|\bteto|max_task_cost_usd|max_budget_usd/iu, text) == []
  end

  @capped_output put_in(@pipeline_output, ["pipeline", "max_task_cost_usd"], 40)
                 |> update_in(["pipeline", "stages"], fn [first | rest] ->
                   [Map.put(first, "max_budget_usd", 2) | rest]
                 end)

  describe "the shared mechanism" do
    test "a directory is studied in a disposable worktree, only by a capable runner", ctx do
      assert {:ok, job} = ask(ctx, "pipeline", %{"request" => "PRs"})
      assert %WireJob{scratch: true, directory: "app"} = wire!(job)
      assert Proposals.kind(job) == "pipeline"

      assert Proposals.input(job) == %{
               "project_id" => ctx.projects["app"].id,
               "directory" => "app",
               "request" => "PRs"
             }

      assert Proposals.title(job) == "PRs"
      assert [listed] = Proposals.list(ctx.workspace)
      assert listed.id == job.id
      assert Proposals.list(ctx.workspace, %{"kind" => "task"}) == []
      assert Proposals.get_proposal!(ctx.workspace, job.id).id == job.id

      assert {:error, changeset} =
               ask(ctx, "pipeline", %{"directory" => "notas", "request" => "x"})

      assert "precisa ser um repositório git do runner" in errors_on(changeset).directory

      {:ok, _old} = Runners.record_hello(ctx.runner, hello_fixture(%{directories: @directories}))
      assert {:error, changeset} = ask(ctx, "pipeline", %{"request" => "x"})
      assert "atualize este runner para gerar propostas" in errors_on(changeset).runner_id

      assert {:error, changeset} =
               Proposals.request("pipeline", ctx.user, ctx.workspace, %{
                 "project_id" => Ecto.UUID.generate(),
                 "request" => "x"
               })

      assert errors_on(changeset).project_id == ["o projeto não existe mais"]
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
        Jobs.create_job(ctx.user, ctx.workspace, %{
          prompt: "x",
          project_id: ctx.projects["app"].id
        })

      refute Proposals.proposal?(job)
      assert_raise Ecto.NoResultsError, fn -> Proposals.get_proposal!(ctx.workspace, job.id) end
    end
  end

  describe "pipeline" do
    test "asks for a pipeline and reads it into the forms' attributes", ctx do
      assert {:ok, job} = ask(ctx, "pipeline", %{"request" => "Um pipeline de entrega com PR"})
      assert job.prompt =~ "diretório `app`"
      assert job.context["output_schema"]["$comment"] == "pipemaestro-kind:pipeline"
      assert job.context["system_prompt"] =~ "worktree descartável"
      assert job.context["system_prompt"] =~ "{{projeto.teste}}"

      assert {:ok, result} = Proposals.result(succeed(ctx, job, @pipeline_output))
      assert result.analysis =~ "Phoenix"

      assert [%{command: "mix test", passed: true}, %{passed: false, note: "2 avisos"}] =
               result.checks

      refute Map.has_key?(result, :project)
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

    test "neither the instructions nor the answer carry a cost cap", ctx do
      {:ok, job} = ask(ctx, "pipeline", %{"request" => "Um pipeline de entrega com PR"})
      refute_budget(job)
      refute_caps(job.context["system_prompt"])
      refute_caps(job.prompt)

      assert {:ok, result} = Proposals.result(succeed(ctx, job, @capped_output))
      refute Map.has_key?(result.pipeline, "max_task_cost_usd")
      assert Enum.all?(result.pipeline["stages"], &(not Map.has_key?(&1, "max_budget_usd")))

      assert {:ok, pipeline} = Pipelines.create_pipeline(ctx.workspace, result.pipeline)
      assert pipeline.max_task_cost_usd == nil
      assert Enum.all?(pipeline.stages, &(&1.max_budget_usd == nil))
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
      assert job.context["output_schema"]["$comment"] == "pipemaestro-kind:task"

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
      assert result.questions == []
      assert result.legacy_questions == ["Qual o timeout aceitável?"]

      assert result.task_params == %{
               "title" => "Destravar o login sob carga",
               "prompt" => output["descricao"],
               "pipeline_id" => pipeline.id,
               "project_id" => ctx.projects["app"].id,
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

    test "triages a linked issue once, with its body cut, on behalf of the trigger's person",
         ctx do
      PipeMaestro.FakeForgejo.start()

      {:ok, project} =
        Projects.update_project(ctx.projects["app"], %{"copy_paths_text" => "deps\nvendor"})

      {:ok, repo} =
        PipeMaestro.Integrations.link_repo(
          connection_fixture(ctx.workspace),
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => project.id},
          "https://pm.test/hook"
        )

      repo = PipeMaestro.Repo.preload(repo, :project)

      trigger = %PipeMaestro.Integrations.Trigger{
        acting_user_id: ctx.user.id,
        auto_approve: false
      }

      issue = %{
        "title" => "Botão quebrado",
        "body" => String.duplicate("a", 40_000),
        "html_url" => "https://forge.test/acme/app/issues/5",
        "number" => 5
      }

      assert {:ok, job} =
               Proposals.triage_linked_issue(ctx.workspace, repo, trigger, issue)

      assert job.created_by_user_id == ctx.user.id
      assert byte_size(job.prompt) < 20_000
      assert Proposals.input(job)["issue_number"] == 5
      # The project's own dependency paths go to the disposable worktree.
      assert job.context["setup"] == %{"copy" => ["deps", "vendor"]}

      assert Proposals.triage_linked_issue(ctx.workspace, repo, trigger, issue) ==
               {:error, :already_triaging}
    end

    test "runs without a cost cap", ctx do
      {:ok, job} = ask(ctx, "task", %{"request" => "x"})
      refute_budget(job)
    end

    test "an answer without a title or description is refused", ctx do
      {:ok, job} = ask(ctx, "task", %{"request" => "x"})

      assert {:error, _} =
               Proposals.result(succeed(ctx, job, %{"titulo" => "", "descricao" => "x"}))
    end
  end

  describe "task: the chosen pipeline" do
    test "a pipeline of another workspace is refused; auto-approval is off unless asked", ctx do
      other = pipeline_fixture(workspace_fixture())

      changeset =
        Proposals.change_request("task", ctx.workspace, %{
          "project_id" => ctx.projects["app"].id,
          "request" => "x",
          "pipeline_id" => other.id
        })

      assert "não é um pipeline deste workspace" in errors_on(changeset).pipeline_id

      changeset =
        Proposals.change_request("task", ctx.workspace, %{
          "project_id" => ctx.projects["app"].id,
          "request" => "x",
          "pipeline_id" => Ecto.UUID.generate()
        })

      assert "não é um pipeline deste workspace" in errors_on(changeset).pipeline_id

      {:ok, job} = ask(ctx, "task", %{"request" => "x"})
      refute Map.has_key?(Proposals.input(job), "auto_approve")
      refute Map.has_key?(Proposals.input(job), "pipeline_id")
    end

    test "the agent writes for the chosen pipeline, whatever it names back", ctx do
      chosen = pipeline_fixture(ctx.workspace, %{"name" => "Funcionalidade"})
      _other = pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})

      {:ok, job} =
        ask(ctx, "task", %{
          "request" => "Exportar CSV",
          "pipeline_id" => chosen.id,
          "auto_approve" => "false"
        })

      assert Proposals.input(job)["pipeline_id"] == chosen.id
      assert Proposals.input(job)["auto_approve"] == false
      assert job.prompt =~ "**Funcionalidade**"
      refute job.prompt =~ "Correção de bug"

      output = %{task_output() | "pipeline" => "Correção de bug"}
      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      assert result.pipeline.id == chosen.id
      assert result.pipeline_name == "Funcionalidade"
      assert result.task_params["pipeline_id"] == chosen.id
    end

    test "a chosen pipeline deleted since falls back to the agent's suggestion", ctx do
      chosen = pipeline_fixture(ctx.workspace, %{"name" => "Funcionalidade"})
      suggested = pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})
      {:ok, job} = ask(ctx, "task", %{"request" => "x", "pipeline_id" => chosen.id})
      {:ok, _deleted} = Pipelines.delete_pipeline(chosen)

      output = %{task_output() | "pipeline" => "Correção de bug"}
      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      assert result.pipeline.id == suggested.id
    end
  end

  describe "task: structured questions (ADR 0029)" do
    setup ctx do
      %{pipeline: pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})}
    end

    defp not_ready(questions),
      do: %{task_output() | "pronta" => false, "perguntas" => questions}

    defp answered_proposal(ctx, attrs \\ %{}) do
      {:ok, job} =
        ask(
          ctx,
          "task",
          Map.merge(%{"request" => "O login trava", "auto_approve" => "false"}, attrs)
        )

      succeed(ctx, job, not_ready(structured_questions()))
    end

    defp both_answered,
      do: [
        %{"escolhas" => ["5 segundos sob qualquer carga"], "outro" => nil},
        %{"escolhas" => [], "outro" => "Só no app móvel"}
      ]

    test "the schema asks for the questionnaire of the stages" do
      assert TaskKind.schema()["properties"]["perguntas"] == Prompt.questions_schema()
      refute "perguntas" in TaskKind.schema()["required"]
    end

    test "the system prompt teaches how to ask", ctx do
      {:ok, job} = ask(ctx, "task", %{"request" => "x"})
      prompt = job.context["system_prompt"]

      assert prompt =~ "recomendada"
      assert prompt =~ "`pronta`"
      assert prompt =~ "Outro"
    end

    test "valid questions come normalized: recommended first, labels and titles cut", ctx do
      {:ok, job} = ask(ctx, "task", %{"request" => "x"})

      assert {:ok, result} =
               Proposals.result(succeed(ctx, job, not_ready(structured_questions())))

      assert [timeout, screens] = result.questions
      assert result.legacy_questions == []
      assert timeout["titulo"] == "Timeout do l"

      assert Enum.map(timeout["opcoes"], & &1["rotulo"]) ==
               ["5 segundos sob qualquer carga", "30 segundos"]

      assert hd(timeout["opcoes"])["recomendada"]
      assert hd(timeout["opcoes"])["preview"] =~ "@timeout"
      assert screens["multipla"]
    end

    test "old phrases are kept apart, and garbage reads as no questions", ctx do
      for {perguntas, legacy} <- [
            {["Qual o timeout?", 3, nil], ["Qual o timeout?"]},
            {"Qual o timeout?", ["Qual o timeout?"]},
            {[%{"pergunta" => "sem opções?"}], []},
            {nil, []},
            {%{"x" => 1}, []}
          ] do
        {:ok, job} = ask(ctx, "task", %{"request" => "x"})
        assert {:ok, result} = Proposals.result(succeed(ctx, job, not_ready(perguntas)))
        assert result.questions == [], inspect(perguntas)
        assert result.legacy_questions == legacy, inspect(perguntas)
      end
    end

    test "the auto-approval's reason lists each question and its options", ctx do
      {:ok, job} = ask(ctx, "task", %{"request" => "O login trava", "auto_approve" => "true"})
      succeed(ctx, job, not_ready(structured_questions()))

      assert %{"status" => "skipped", "reason" => reason} =
               Proposals.auto_approve(Jobs.get_job!(ctx.workspace, job.id))

      assert reason =~ "O agente não considerou a tarefa pronta."
      assert reason =~ ~r/1\. .*Qual o timeout aceitável\?/
      assert reason =~ "5 segundos sob qualquer carga (recomendada)"
      assert reason =~ "30 segundos"
      assert reason =~ ~r/2\. .*Quais telas mostram o erro\?/
    end

    test "the auto-approval's reason still lists old phrases", ctx do
      {:ok, job} = ask(ctx, "task", %{"request" => "O login trava", "auto_approve" => "true"})
      succeed(ctx, job, not_ready(["Qual o timeout aceitável?"]))

      assert %{"status" => "skipped", "reason" => reason} =
               Proposals.auto_approve(Jobs.get_job!(ctx.workspace, job.id))

      assert reason =~ "- Qual o timeout aceitável?"
    end

    test "answering asks a new round with the answers as its feedback", ctx do
      job = answered_proposal(ctx)

      assert {:ok, next} =
               Proposals.answer_questions(ctx.user, ctx.workspace, job, both_answered())

      assert next.id != job.id
      assert Proposals.kind(next) == "task"
      input = Proposals.input(next)
      assert input["request"] == "O login trava"
      assert input["project_id"] == ctx.projects["app"].id
      assert input["auto_approve"] == false

      feedback = input["feedback"]
      assert feedback =~ "Respostas às suas perguntas"
      assert feedback =~ "Qual o timeout aceitável?"
      assert feedback =~ "5 segundos sob qualquer carga"
      assert feedback =~ "Quais telas mostram o erro?"
      assert feedback =~ "Só no app móvel"

      # The new round revises the last one, telling the agent these answer it.
      assert next.prompt =~ "Sua proposta anterior"
      assert next.prompt =~ "Respostas às suas perguntas"
      assert next.prompt =~ "descrição da tarefa"

      assert Enum.any?(
               Audit.list_events(ctx.workspace),
               &(&1.action == "proposal.answered" and &1.subject_id == next.id)
             )
    end

    test "a long Other is cut, but every answer stays and the request is accepted", ctx do
      job = answered_proposal(ctx)
      long = String.duplicate("muito texto ", 1_500)

      answers = [
        %{"escolhas" => [], "outro" => "Fim: " <> long},
        %{"escolhas" => ["Login"], "outro" => long}
      ]

      assert {:ok, next} = Proposals.answer_questions(ctx.user, ctx.workspace, job, answers)
      feedback = Proposals.input(next)["feedback"]

      assert String.length(feedback) <= 8_000
      assert feedback =~ "Qual o timeout aceitável?"
      assert feedback =~ "Fim: muito texto"
      assert feedback =~ "Quais telas mostram o erro?"
      assert feedback =~ "Login"
    end

    test "the feedback of a round takes up to 8 000 characters", ctx do
      assert {:ok, _job} =
               ask(ctx, "task", %{"request" => "x", "feedback" => String.duplicate("a", 8_000)})

      assert {:error, changeset} =
               ask(ctx, "task", %{"request" => "x", "feedback" => String.duplicate("a", 8_001)})

      assert errors_on(changeset)[:feedback]
    end

    test "incomplete or invalid answers are refused, and nothing is asked", ctx do
      job = answered_proposal(ctx)

      for answers <- [
            [%{"escolhas" => ["30 segundos"], "outro" => nil}],
            [%{"escolhas" => [], "outro" => ""}, %{"escolhas" => ["Login"]}],
            [%{"escolhas" => ["Nenhuma"]}, %{"escolhas" => ["Login"]}],
            "lixo"
          ] do
        assert {:error, reason} =
                 Proposals.answer_questions(ctx.user, ctx.workspace, job, answers)

        assert is_binary(reason)
      end

      assert length(Jobs.list_jobs(ctx.workspace)) == 1
    end

    test "only a finished task proposal with questions, not made a task yet, is answered",
         ctx do
      {:ok, running} = ask(ctx, "task", %{"request" => "x"})

      assert {:error, _reason} =
               Proposals.answer_questions(ctx.user, ctx.workspace, running, both_answered())

      {:ok, ready} = ask(ctx, "task", %{"request" => "x"})
      ready = succeed(ctx, ready, %{task_output() | "perguntas" => []})

      assert {:error, _reason} =
               Proposals.answer_questions(ctx.user, ctx.workspace, ready, both_answered())

      job = answered_proposal(ctx)
      {:ok, result} = Proposals.result(job)

      {:ok, _task} =
        Proposals.create_task(ctx.user, ctx.workspace, job, %{
          result.task_params
          | "pipeline_id" => ctx.pipeline.id
        })

      job = Jobs.get_job!(ctx.workspace, job.id)

      assert {:error, _reason} =
               Proposals.answer_questions(ctx.user, ctx.workspace, job, both_answered())

      {:ok, pipeline} = ask(ctx, "pipeline", %{"request" => "PRs"})
      pipeline = succeed(ctx, pipeline, @pipeline_output)

      assert {:error, _reason} =
               Proposals.answer_questions(ctx.user, ctx.workspace, pipeline, both_answered())
    end
  end

  describe "task: auto-approval" do
    setup ctx do
      %{pipeline: pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})}
    end

    defp ask_auto(ctx, attrs \\ %{}) do
      {:ok, job} =
        ask(
          ctx,
          "task",
          Map.merge(%{"request" => "O login trava", "auto_approve" => "true"}, attrs)
        )

      job
    end

    defp reload(ctx, job), do: Jobs.get_job!(ctx.workspace, job.id)

    defp proposal_tasks(job),
      do: Repo.all(from t in Task, where: t.proposal_job_id == ^job.id)

    test "a ready task is created and started on behalf of who asked", ctx do
      job = ask_auto(ctx)
      assert Proposals.input(job)["auto_approve"] == true

      succeed(ctx, job, task_output())

      assert [task] = proposal_tasks(job)
      assert task.status == :running
      assert task.title == "Destravar o login sob carga"
      assert task.pipeline_id == ctx.pipeline.id
      assert task.created_by_user_id == ctx.user.id

      job = reload(ctx, job)
      assert Proposals.created_task_id(job) == task.id
      assert job.context["proposal"]["created_task_id"] == task.id
      assert Proposals.auto_approve(job) == %{"status" => "created"}

      assert Enum.any?(
               Audit.list_events(ctx.workspace),
               &(&1.action == "task.auto_created" and &1.subject_id == task.id and
                   &1.actor_user_id == ctx.user.id and &1.details["proposal_id"] == job.id)
             )
    end

    test "past the workspace's limit the created task waits in line", ctx do
      {:ok, workspace} = Workspaces.update_workspace(ctx.workspace, %{"max_running_tasks" => 1})
      ctx = %{ctx | workspace: workspace}

      {:ok, _running} =
        Tasks.create_task(ctx.user, workspace, %{
          "title" => "Outra",
          "prompt" => "x",
          "pipeline_id" => ctx.pipeline.id,
          "project_id" => ctx.projects["app"].id
        })

      job = ask_auto(ctx)
      succeed(ctx, job, task_output())
      assert [%Task{status: :queued}] = proposal_tasks(job)
    end

    test "a task the agent finds not ready stays for review, saying why", ctx do
      job = ask_auto(ctx)
      succeed(ctx, job, %{task_output() | "pronta" => false})

      assert proposal_tasks(job) == []
      job = reload(ctx, job)
      assert Proposals.created_task_id(job) == nil
      assert %{"status" => "skipped", "reason" => reason} = Proposals.auto_approve(job)
      assert reason =~ "pronta"
      assert reason =~ "Qual o timeout aceitável?"
    end

    test "no pipeline resolved: no task, and the reason names the suggestion", ctx do
      job = ask_auto(ctx)
      succeed(ctx, job, %{task_output() | "pipeline" => "Inexistente"})

      assert proposal_tasks(job) == []

      assert %{"status" => "skipped", "reason" => reason} =
               Proposals.auto_approve(reload(ctx, job))

      assert reason =~ "Inexistente"
    end

    test "a task that cannot be created stays for review with the error", ctx do
      job = ask_auto(ctx)
      # The runner stops offering the directory while the agent works.
      with_directories(ctx.runner, [%{"name" => "outro", "git" => true}])
      succeed(ctx, job, task_output())

      assert proposal_tasks(job) == []

      assert %{"status" => "skipped", "reason" => reason} =
               Proposals.auto_approve(reload(ctx, job))

      assert reason =~ "o runner não oferece esse diretório"
    end

    test "without auto-approval (or from before it) nothing is created nor recorded", ctx do
      for attrs <- [%{"auto_approve" => "false"}, %{}] do
        {:ok, job} = ask(ctx, "task", Map.merge(%{"request" => "x"}, attrs))
        succeed(ctx, job, task_output())

        assert proposal_tasks(job) == []
        job = reload(ctx, job)
        assert Proposals.auto_approve(job) == nil
        assert Proposals.created_task_id(job) == nil
      end
    end

    test "a failed proposal creates nothing", ctx do
      job = ask_auto(ctx)
      finish(ctx, job, %{"status" => "failed", "error" => "sem créditos"})
      assert proposal_tasks(job) == []
    end

    test "finishing twice or creating by hand afterwards makes a single task", ctx do
      job = ask_auto(ctx)
      job = succeed(ctx, job, task_output())
      assert [task] = proposal_tasks(job)

      job = reload(ctx, job)
      assert :ok = Proposals.job_finished(job)
      assert [%Task{id: id}] = proposal_tasks(job)
      assert id == task.id

      {:ok, result} = Proposals.result(job)

      assert {:error, changeset} =
               Proposals.create_task(ctx.user, ctx.workspace, job, result.task_params)

      assert "esta proposta já virou uma tarefa" in errors_on(changeset).proposal_job_id
      assert length(proposal_tasks(job)) == 1
    end

    test "creating by hand links the task to the proposal", ctx do
      {:ok, job} = ask(ctx, "task", %{"request" => "x", "auto_approve" => "false"})
      job = succeed(ctx, job, task_output())
      {:ok, result} = Proposals.result(job)

      assert {:ok, task} =
               Proposals.create_task(ctx.user, ctx.workspace, job, result.task_params)

      assert task.proposal_job_id == job.id
      assert Proposals.created_task_id(reload(ctx, job)) == task.id
    end

    test "other kinds of proposal are left alone", ctx do
      {:ok, job} = ask(ctx, "pipeline", %{"request" => "PRs"})
      job = succeed(ctx, job, @pipeline_output)
      assert :ok = Proposals.job_finished(job)
      assert Proposals.auto_approve(reload(ctx, job)) == nil
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
          "project_id" => ctx.projects["app"].id
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

    test "runs without a cost cap", ctx do
      {:ok, job} =
        Proposals.request("decision", ctx.user, ctx.workspace, %{"task_id" => ctx.task.id})

      refute_budget(job)
    end

    test "an answer without a known action is refused", ctx do
      {:ok, job} =
        Proposals.request("decision", ctx.user, ctx.workspace, %{"task_id" => ctx.task.id})

      assert {:error, _} = Proposals.result(succeed(ctx, job, %{"acao" => "pular"}))
    end
  end

  describe "analysis" do
    setup ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{"key" => "a", "name" => "Etapa A", "prompt" => "Faça A", "max_attempts" => 1},
            %{"key" => "b", "name" => "Etapa B", "prompt" => "Faça B"}
          ]
        })

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "Corrigir o login",
          "prompt" => "O botão não responde",
          "pipeline_id" => pipeline.id,
          "project_id" => ctx.projects["app"].id
        })

      stage_job = hd(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
      {:ok, _} = Jobs.mark_started(ctx.runner, stage_job.id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, stage_job.id, %{
          "status" => "failed",
          "exit_code" => 1,
          "error" => "mix test: 1 failure em LoginTest",
          "changes" => %{"patch" => "diff --git a/login.ex b/login.ex\n+timeout"}
        })

      task = Tasks.get_task!(ctx.workspace, task.id)

      # The automatic analysis the failure asked for, if any: each test asserts it.
      job =
        case Map.get(task, :decision_analysis_job_id) do
          nil -> nil
          id -> Jobs.get_job!(ctx.workspace, id)
        end

      %{task: task, job: job}
    end

    defp analysis!(%{job: job}) do
      assert %PipeMaestro.Jobs.Job{} = job, "expected the failure to ask for an analysis"
      job
    end

    @analysis %{
      "diagnostico" => "O **timeout** do login é curto.",
      "perguntas" => [
        %{
          "titulo" => "Correção",
          "pergunta" => "Como corrigir a falha?",
          "multipla" => false,
          "opcoes" => [
            %{"rotulo" => "Desistir", "descricao" => "Cancela", "recomendada" => false},
            %{"rotulo" => "Tentar sem falha", "descricao" => "Timeout", "recomendada" => true}
          ]
        }
      ]
    }

    test "is a kind of its own, listed and filtered with the others", ctx do
      assert "analysis" in Proposals.kinds()
      assert Proposals.kind_module("analysis") == AnalysisKind
      assert AnalysisKind.label() == "Análise de falha"
      assert AnalysisKind.icon() == "hero-magnifying-glass"

      job = analysis!(ctx)

      assert [listed] = Proposals.list(ctx.workspace, %{"kind" => "analysis"})
      assert listed.id == job.id
    end

    test "studies the paused task in a disposable worktree when the runner can", ctx do
      job = analysis!(ctx)
      assert Proposals.kind(job) == "analysis"
      assert %WireJob{scratch: true, directory: "app"} = wire!(job)
      assert job.prompt =~ "O botão não responde"
      assert job.prompt =~ "1 failure em LoginTest"
      assert job.prompt =~ "+timeout"
      refute_budget(job)
      refute_caps(job.prompt <> job.context["system_prompt"])
      assert job.context["timeout_ms"] == 10 * 60 * 1000

      schema = job.context["output_schema"]
      assert schema == AnalysisKind.schema()
      assert schema["properties"]["perguntas"] == Prompt.questions_schema()
      assert Map.has_key?(schema["properties"], "diagnostico")
    end

    test "the result is a diagnosis and valid questions", ctx do
      job = analysis!(ctx)
      assert {:ok, result} = Proposals.result(succeed(ctx, job, @analysis))
      assert result.task_id == ctx.task.id
      assert result.diagnosis =~ "timeout"
      assert [question] = result.questions
      assert hd(question["opcoes"])["rotulo"] == "Tentar sem falha"
    end

    test "an answer without valid questions is refused", ctx do
      job = analysis!(ctx)
      output = %{"diagnostico" => "x", "perguntas" => [%{"pergunta" => "sem opções"}]}
      assert {:error, _} = Proposals.result(succeed(ctx, job, output))
    end

    test "is only current for the pause it was asked about", ctx do
      job = analysis!(ctx)
      input = Proposals.input(job)
      assert AnalysisKind.current?(input, ctx.task)

      {:ok, task} = Tasks.retry_stage(ctx.task, "de novo", by: ctx.user)
      refute AnalysisKind.current?(input, Tasks.get_task!(ctx.workspace, task.id))
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
          "project_id" => ctx.projects["app"].id
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
        Projects.update_project(ctx.projects["app"], %{"name" => "App", "notes" => "Notas velhas"})

      assert {:ok, job} =
               ask(ctx, "improve", %{"pipeline_id" => ctx.pipeline.id, "focus" => "Custo"})

      assert %WireJob{scratch: true} = wire!(job)
      assert Proposals.title(job) == "Entrega"
      assert job.prompt =~ "Foco pedido pela pessoa"
      assert job.prompt =~ "Notas velhas"
      assert job.prompt =~ "```yaml"
      assert job.context["output_schema"]["$comment"] == "pipemaestro-kind:improve"

      output = %{
        "analise" => "O gate falha muito.",
        "mudancas" => [%{"onde" => "Etapa A", "o_que" => "gate", "por_que" => "falhou"}],
        "pipeline" => @pipeline_output["pipeline"],
        "notas" => "Notas novas"
      }

      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      assert result.pipeline_id == ctx.pipeline.id
      assert result.project_id == ctx.projects["app"].id
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

    test "keeps the pipeline's own caps, which the agent never sees", ctx do
      {:ok, capped} =
        Pipelines.create_pipeline(ctx.workspace, %{
          "name" => "Limitado",
          "max_task_cost_usd" => "40",
          "stages" => [
            %{"key" => "plano", "name" => "Plano", "prompt" => "p", "max_budget_usd" => "1.5"},
            %{"key" => "codigo", "name" => "Código", "prompt" => "c", "max_budget_usd" => "3"}
          ]
        })

      assert {:ok, job} = ask(ctx, "improve", %{"pipeline_id" => capped.id})
      refute_budget(job)
      refute_caps(job.context["system_prompt"])
      refute_caps(job.prompt)

      # The agent answers with a cap of its own, none on `plano`, drops
      # `codigo` and adds `revisao`.
      revised = %{
        "name" => "Limitado",
        "max_task_cost_usd" => 5,
        "stages" => [
          %{"key" => "plano", "name" => "Plano", "prompt" => "p2"},
          %{"key" => "revisao", "name" => "Revisão", "prompt" => "r", "max_budget_usd" => 9}
        ]
      }

      output = %{"analise" => "x", "mudancas" => [], "pipeline" => revised, "notas" => "n"}
      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      assert result.pipeline["max_task_cost_usd"] == "40"

      assert [plano, revisao] = result.pipeline["stages"]
      assert plano["max_budget_usd"] == "1.5"
      refute Map.has_key?(revisao, "max_budget_usd")

      assert {:ok, saved} = Pipelines.update_pipeline(capped, result.pipeline)
      assert Decimal.equal?(saved.max_task_cost_usd, Decimal.new("40"))
      assert [%{max_budget_usd: plano_cap}, %{max_budget_usd: nil}] = saved.stages
      assert Decimal.equal?(plano_cap, Decimal.new("1.5"))
    end

    test "a pipeline without caps is improved without caps", ctx do
      {:ok, job} = ask(ctx, "improve", %{"pipeline_id" => ctx.pipeline.id})
      output = %{"analise" => "x", "mudancas" => [], "pipeline" => @capped_output["pipeline"]}

      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      refute Map.has_key?(result.pipeline, "max_task_cost_usd")
      assert Enum.all?(result.pipeline["stages"], &(not Map.has_key?(&1, "max_budget_usd")))
    end

    test "keeps the pipeline's automatic analysis setting, a person's choice", ctx do
      {:ok, off} = Pipelines.update_pipeline(ctx.pipeline, %{"auto_analysis" => "false"})
      {:ok, job} = ask(ctx, "improve", %{"pipeline_id" => off.id})

      revised = Map.put(@pipeline_output["pipeline"], "auto_analysis", true)
      output = %{"analise" => "x", "mudancas" => [], "pipeline" => revised}

      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      assert result.pipeline["auto_analysis"] == false
      assert {:ok, %{auto_analysis: false}} = Pipelines.update_pipeline(off, result.pipeline)
    end

    test "refuses another workspace's pipeline", ctx do
      assert {:error, changeset} = ask(ctx, "improve", %{"pipeline_id" => Ecto.UUID.generate()})
      assert "não é um pipeline deste workspace" in errors_on(changeset).pipeline_id
    end
  end

  describe "the schemas" do
    # The CLI checks `--json-schema` in strict mode: a keyword it does not know
    # (such as an `x-` extension) fails the run before it starts.
    test "use only JSON Schema keywords; the kind goes in $comment" do
      for kind <- Proposals.kinds() do
        schema = Proposals.kind_module(kind).schema()
        assert schema["$comment"] == "pipemaestro-kind:#{kind}"
        assert extensions(schema) == [], "#{kind}: #{inspect(extensions(schema))}"
      end

      stage = Prompt.output_schema(%Stage{})
      assert extensions(stage) == []
    end

    test "a pipeline in an answer has no cost cap" do
      for schema <- [
            PipelineKind.pipeline_schema(),
            ImproveKind.schema()["properties"]["pipeline"]
          ] do
        refute Map.has_key?(schema["properties"], "max_task_cost_usd")

        refute Map.has_key?(
                 schema["properties"]["stages"]["items"]["properties"],
                 "max_budget_usd"
               )
      end

      assert PipelineKind.schema()["properties"]["pipeline"] == PipelineKind.pipeline_schema()
    end

    test "how a pipeline works says nothing of a cost cap" do
      refute_caps(Instructions.pipeline_format())
    end
  end

  # Every key that starts with "x-", at any depth, outside of "properties"
  # (whose keys are the answer's field names).
  defp extensions(%{} = schema) do
    Enum.flat_map(schema, fn
      {"properties", %{} = properties} ->
        properties |> Map.values() |> Enum.flat_map(&extensions/1)

      {"x-" <> _ = key, _value} ->
        [key]

      {_key, value} ->
        extensions(value)
    end)
  end

  defp extensions(list) when is_list(list), do: Enum.flat_map(list, &extensions/1)
  defp extensions(_value), do: []
end
