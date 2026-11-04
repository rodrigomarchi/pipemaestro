defmodule PipeMaestro.ProposalsTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, Pipelines, Projects, Proposals, Runners}
  alias PipeMaestroProtocol.Job, as: WireJob

  @directories [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}]

  @output %{
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

  defp ask(ctx, attrs \\ %{}) do
    Proposals.request(
      ctx.user,
      ctx.workspace,
      Map.merge(%{"runner_id" => ctx.runner.id, "directory" => "app", "request" => "PRs"}, attrs)
    )
  end

  test "asks the runner for an analysis in a disposable worktree of the directory", ctx do
    assert {:ok, job} = ask(ctx, %{"request" => "Um pipeline de entrega com PR"})

    assert job.prompt =~ "diretório `app`"
    assert job.prompt =~ "Um pipeline de entrega com PR"
    assert job.context["scratch"] == true
    assert job.context["directory"] == "app"
    assert job.context["output_schema"]["required"] == ~w(analise verificacoes projeto pipeline)
    assert job.context["system_prompt"] =~ "worktree descartável"
    assert job.context["system_prompt"] =~ "{{projeto.teste}}"
    assert Proposals.proposal?(job)
    assert Proposals.asked(job) == %{directory: "app", request: "Um pipeline de entrega com PR"}

    # What reaches the runner is a valid job; the proposal marker stays here.
    wire = Map.merge(job.context, %{"id" => job.id, "prompt" => job.prompt})
    assert {:ok, %WireJob{scratch: true, directory: "app"} = parsed} = WireJob.new(wire)
    refute Map.has_key?(WireJob.to_map(parsed), "proposal")

    assert [listed] = Proposals.list_recent(ctx.workspace)
    assert listed.id == job.id
    assert Proposals.get_proposal!(ctx.workspace, job.id).id == job.id
  end

  test "refuses a runner without the capability, a directory without git, a missing request",
       ctx do
    assert {:error, changeset} = ask(ctx, %{"directory" => "notas"})
    assert "precisa ser um repositório git do runner" in errors_on(changeset).directory

    assert {:error, changeset} = ask(ctx, %{"request" => ""})
    assert "conte o que o pipeline deve fazer" in errors_on(changeset).request

    {:ok, old} =
      Runners.record_hello(ctx.runner, hello_fixture(%{directories: @directories}))

    refute Proposals.capable?(old)
    assert {:error, changeset} = ask(ctx)
    assert "atualize este runner para gerar propostas" in errors_on(changeset).runner_id

    assert {:error, changeset} = ask(ctx, %{"runner_id" => Ecto.UUID.generate()})
    assert errors_on(changeset).runner_id != []
  end

  test "a new round carries the last proposal and the person's comment", ctx do
    {:ok, first} = ask(ctx)
    first = finish(ctx, first, %{"status" => "succeeded", "structured_output" => @output})

    {:ok, second} =
      Proposals.request(
        ctx.user,
        ctx.workspace,
        %{
          "runner_id" => ctx.runner.id,
          "directory" => "app",
          "request" => "PRs",
          "feedback" => "Junte plano e código"
        },
        first
      )

    assert second.prompt =~ "Sua proposta anterior"
    assert second.prompt =~ "Entrega do App"
    assert second.prompt =~ "Junte plano e código"
  end

  test "reads a finished proposal into the project and pipeline forms' attributes", ctx do
    {:ok, job} = ask(ctx)
    job = finish(ctx, job, %{"status" => "succeeded", "structured_output" => @output})

    assert {:ok, result} = Proposals.result(job)
    assert result.analysis =~ "Phoenix"

    assert result.checks == [
             %{command: "mix test", passed: true, note: ""},
             %{command: "mix credo", passed: false, note: "2 avisos"}
           ]

    assert result.project["directory"] == "app"
    assert result.project["copy_paths_text"] == "deps\n_build"
    assert {:ok, project} = Projects.create_project(ctx.workspace, result.project, ctx.user)
    assert project.test_command == "mix test"

    assert [_plano, %{"gates_text" => "{{projeto.teste}}"}] = result.pipeline["stages"]
    assert {:ok, pipeline} = Pipelines.create_pipeline(ctx.workspace, result.pipeline)
    assert pipeline.delivery == "pr"
    assert length(pipeline.stages) == 2
  end

  test "a proposal that failed or came back incomplete says why", ctx do
    {:ok, job} = ask(ctx)
    failed = finish(ctx, job, %{"status" => "failed", "error" => "sem créditos"})
    assert Proposals.result(failed) == {:error, "sem créditos"}

    {:ok, job} = ask(ctx)

    empty =
      finish(ctx, job, %{"status" => "succeeded", "structured_output" => %{"analise" => "x"}})

    assert {:error, "O agente não devolveu" <> _} = Proposals.result(empty)

    {:ok, job} = ask(ctx)
    none = finish(ctx, job, %{"status" => "succeeded"})
    assert {:error, "O agente terminou sem" <> _} = Proposals.result(none)
  end

  test "a job that is not a proposal is not found as one", ctx do
    {:ok, job} =
      Jobs.create_job(ctx.user, ctx.workspace, %{prompt: "x", runner_id: ctx.runner.id})

    refute Proposals.proposal?(job)
    assert_raise Ecto.NoResultsError, fn -> Proposals.get_proposal!(ctx.workspace, job.id) end
  end

  defp finish(ctx, job, attrs) do
    {:ok, _started} = Jobs.mark_started(ctx.runner, job.id)
    {:ok, job} = Jobs.finish_job(ctx.runner, job.id, attrs)
    job
  end
end
