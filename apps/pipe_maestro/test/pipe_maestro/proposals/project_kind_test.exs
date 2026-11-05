defmodule PipeMaestro.Proposals.ProjectKindTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, Projects, Proposals, Repo, Runners, Tasks}
  alias PipeMaestro.Proposals.{PipelineKind, ProjectKind}

  @directories [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}]

  @project_output %{
    "analise" => "Um app Phoenix. Testes com `mix test`.",
    "verificacoes" => [%{"comando" => "mix test", "passou" => true}],
    "projeto" => %{
      "nome" => "App",
      "setup" => "mix deps.get",
      "teste" => "mix test",
      "lint" => "mix credo --strict",
      "copy_paths" => ["deps", "_build"],
      "notas" => "Use `make ci`."
    }
  }

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{directories: @directories, capabilities: ["scratch"]})
      )

    {:ok, project} =
      Projects.create_project(
        workspace,
        %{
          "name" => "App",
          "runner_id" => runner.id,
          "directory" => "app",
          "copy_paths_text" => "deps"
        },
        user
      )

    %{workspace: workspace, user: user, runner: runner, project: project}
  end

  defp succeed(ctx, job, output) do
    {:ok, _started} = Jobs.mark_started(ctx.runner, job.id)

    {:ok, job} =
      Jobs.finish_job(ctx.runner, job.id, %{
        "status" => "succeeded",
        "structured_output" => output
      })

    job
  end

  describe "the project kind" do
    test "is a kind of its own" do
      assert "project" in Proposals.kinds()
      assert Proposals.kind_module("project") == ProjectKind
      assert ProjectKind.name() == "project"
    end

    test "studies a runner's directory before the project exists, in a disposable worktree",
         ctx do
      assert {:ok, job} =
               Proposals.request("project", ctx.user, ctx.workspace, %{
                 "runner_id" => ctx.runner.id,
                 "directory" => "app"
               })

      assert Proposals.kind(job) == "project"
      assert job.runner_id == ctx.runner.id
      assert job.project_id == nil
      assert job.context["directory"] == "app"
      assert job.context["scratch"] == true
      assert job.context["output_schema"]["$comment"] == "pipemaestro-kind:project"
      assert job.prompt =~ "`app`"
    end

    test "refuses a directory without git and a runner that must be updated", ctx do
      assert {:error, changeset} =
               Proposals.request("project", ctx.user, ctx.workspace, %{
                 "runner_id" => ctx.runner.id,
                 "directory" => "notas"
               })

      assert "precisa ser um repositório git do runner" in errors_on(changeset).directory

      {:ok, _old} = Runners.record_hello(ctx.runner, hello_fixture(%{directories: @directories}))

      assert {:error, changeset} =
               Proposals.request("project", ctx.user, ctx.workspace, %{
                 "runner_id" => ctx.runner.id,
                 "directory" => "app"
               })

      assert "atualize este runner para gerar propostas" in errors_on(changeset).runner_id
    end

    test "the answer fills the project form, with the runner and the directory asked", ctx do
      {:ok, job} =
        Proposals.request("project", ctx.user, ctx.workspace, %{
          "runner_id" => ctx.runner.id,
          "directory" => "app",
          "request" => "Use o Makefile"
        })

      assert job.prompt =~ "Use o Makefile"
      assert {:ok, result} = Proposals.result(succeed(ctx, job, @project_output))
      assert result.analysis =~ "Phoenix"
      assert [%{command: "mix test", passed: true}] = result.checks

      assert result.project == %{
               "name" => "App",
               "runner_id" => ctx.runner.id,
               "directory" => "app",
               "setup_command" => "mix deps.get",
               "test_command" => "mix test",
               "lint_command" => "mix credo --strict",
               "copy_paths_text" => "deps\n_build",
               "notes" => "Use `make ci`."
             }

      # Nothing is saved until the person saves the form.
      assert length(Projects.list_projects(ctx.workspace)) == 1
    end

    test "an answer without a project is refused", ctx do
      {:ok, job} =
        Proposals.request("project", ctx.user, ctx.workspace, %{
          "runner_id" => ctx.runner.id,
          "directory" => "app"
        })

      assert {:error, _reason} = Proposals.result(succeed(ctx, job, %{"analise" => "x"}))
    end

    test "the schema asks for the analysis, the checks and the project" do
      schema = ProjectKind.schema()
      assert schema["required"] == ["analise", "verificacoes", "projeto"]
      assert schema["properties"]["projeto"]["required"] == ["nome"]
    end
  end

  describe "the other kinds take only a project" do
    test "a task is written on the project's runner and directory", ctx do
      pipeline = pipeline_fixture(ctx.workspace, %{"name" => "Correção de bug"})

      assert {:ok, job} =
               Proposals.request("task", ctx.user, ctx.workspace, %{
                 "project_id" => ctx.project.id,
                 "request" => "O login trava"
               })

      assert job.runner_id == ctx.runner.id
      assert job.project_id == ctx.project.id
      assert job.context["directory"] == "app"
      assert job.context["scratch"] == true
      assert job.context["setup"] == %{"copy" => ["deps"]}

      output = %{
        "analise" => "x",
        "titulo" => "Destravar o login",
        "descricao" => "O lock não tem timeout.",
        "pipeline" => "correção de bug",
        "pronta" => true
      }

      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))

      assert result.task_params == %{
               "title" => "Destravar o login",
               "prompt" => "O lock não tem timeout.",
               "pipeline_id" => pipeline.id,
               "project_id" => ctx.project.id
             }

      assert {:ok, task} = Tasks.create_task(ctx.user, ctx.workspace, result.task_params)
      assert task.project_id == ctx.project.id
    end

    test "a runner and a directory alone are not enough", ctx do
      assert {:error, changeset} =
               Proposals.request("task", ctx.user, ctx.workspace, %{
                 "runner_id" => ctx.runner.id,
                 "directory" => "app",
                 "request" => "x"
               })

      assert %{project_id: ["escolha um projeto"]} = errors_on(changeset)
    end

    test "a project without a runner cannot be studied", ctx do
      Repo.delete!(ctx.runner)

      assert {:error, changeset} =
               Proposals.request("task", ctx.user, ctx.workspace, %{
                 "project_id" => ctx.project.id,
                 "request" => "x"
               })

      assert %{project_id: ["o projeto precisa de um runner"]} = errors_on(changeset)
    end

    test "a pipeline is proposed for an existing project, without proposing the project",
         ctx do
      assert {:error, changeset} =
               Proposals.request("pipeline", ctx.user, ctx.workspace, %{
                 "runner_id" => ctx.runner.id,
                 "directory" => "app",
                 "request" => "PRs"
               })

      assert %{project_id: ["escolha um projeto"]} = errors_on(changeset)

      assert {:ok, job} =
               Proposals.request("pipeline", ctx.user, ctx.workspace, %{
                 "project_id" => ctx.project.id,
                 "request" => "PRs"
               })

      assert job.project_id == ctx.project.id
      refute Map.has_key?(PipelineKind.schema()["properties"], "projeto")
      refute "projeto" in PipelineKind.schema()["required"]

      # An answer from before, with a project in it, still reads.
      output = %{
        "analise" => "x",
        "verificacoes" => [],
        "projeto" => %{"nome" => "Antigo"},
        "pipeline" => %{
          "name" => "Entrega",
          "stages" => [%{"key" => "a", "name" => "A", "prompt" => "Faça"}]
        }
      }

      assert {:ok, result} = Proposals.result(succeed(ctx, job, output))
      assert result.pipeline["name"] == "Entrega"
      refute Map.has_key?(result, :project)
    end

    test "proposals are filtered by project", ctx do
      {:ok, job} =
        Proposals.request("task", ctx.user, ctx.workspace, %{
          "project_id" => ctx.project.id,
          "request" => "x"
        })

      assert [%{id: id}] = Proposals.list(ctx.workspace, %{"project_id" => ctx.project.id})
      assert id == job.id
      assert Proposals.list(ctx.workspace, %{"project_id" => Ecto.UUID.generate()}) == []
    end
  end

  describe "triage_issue/3" do
    test "triages on the project's runner", ctx do
      pipeline = pipeline_fixture(ctx.workspace)

      {:ok, project} =
        Projects.update_project(
          ctx.project,
          %{
            "github_repo" => "acme/app",
            "trigger_label" => "ia",
            "trigger_pipeline_id" => pipeline.id,
            "trigger_mode" => "triage"
          },
          ctx.user
        )

      issue = %{
        "title" => "Botão quebrado",
        "body" => "Nada acontece.",
        "html_url" => "https://github.com/acme/app/issues/5"
      }

      assert {:ok, job} = Proposals.triage_issue(ctx.workspace, project, issue)
      assert job.runner_id == ctx.runner.id
      assert job.project_id == project.id
      assert job.context["directory"] == "app"
    end
  end
end
