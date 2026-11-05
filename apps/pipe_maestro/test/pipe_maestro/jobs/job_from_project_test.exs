defmodule PipeMaestro.Jobs.JobFromProjectTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Jobs, Projects, Repo, Runners}
  alias PipeMaestro.Jobs.Job

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}],
          capabilities: ["scratch"]
        })
      )

    {:ok, project} =
      Projects.create_project(workspace, %{
        "name" => "App",
        "runner_id" => runner.id,
        "directory" => "app",
        "setup_command" => "mix deps.get",
        "copy_paths_text" => "deps\n_build"
      })

    %{workspace: workspace, user: user, runner: runner, project: project}
  end

  describe "create_job/3 from a project" do
    test "goes to the project's runner, in a disposable worktree set up from the project",
         ctx do
      :ok = Jobs.subscribe({:runner, ctx.runner.id})

      assert {:ok, %Job{status: :queued} = job} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "diga oi",
                 "project_id" => ctx.project.id
               })

      assert job.runner_id == ctx.runner.id
      assert job.project_id == ctx.project.id
      assert job.context["directory"] == "app"
      assert job.context["scratch"] == true
      assert job.context["setup"] == %{"command" => "mix deps.get", "copy" => ["deps", "_build"]}

      assert_receive {:job_assign, %Job{id: id}} when id == job.id
    end

    test "a runner from the form is ignored: the project decides", ctx do
      {other, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: "outro"})

      assert {:ok, job} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "x",
                 "project_id" => ctx.project.id,
                 "runner_id" => other.id
               })

      assert job.runner_id == ctx.runner.id
    end

    test "every job needs a project", ctx do
      assert {:error, changeset} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "x",
                 "runner_id" => ctx.runner.id
               })

      assert %{project_id: ["escolha um projeto"]} = errors_on(changeset)
    end

    test "a project of another workspace is not there", ctx do
      other = workspace_fixture()
      {runner, _token} = runner_fixture(other, member_fixture(other))
      with_directories(runner, [%{"name" => "app", "git" => true}])

      {:ok, foreign} =
        Projects.create_project(other, %{
          "name" => "Fora",
          "runner_id" => runner.id,
          "directory" => "app"
        })

      assert {:error, changeset} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "x",
                 "project_id" => foreign.id
               })

      assert %{project_id: ["o projeto não existe mais"]} = errors_on(changeset)
    end

    test "a project whose directory has no git cannot run on its own", ctx do
      {:ok, notes} =
        Projects.create_project(ctx.workspace, %{
          "name" => "Notas",
          "runner_id" => ctx.runner.id,
          "directory" => "notas"
        })

      assert {:error, changeset} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "x",
                 "project_id" => notes.id
               })

      assert %{project_id: ["a pasta do projeto não é um repositório git"]} =
               errors_on(changeset)
    end

    test "a runner that cannot make a disposable worktree must be updated", ctx do
      with_directories(ctx.runner, [%{"name" => "app", "git" => true}])

      assert {:error, changeset} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "x",
                 "project_id" => ctx.project.id
               })

      assert %{project_id: ["o runner precisa ser atualizado"]} = errors_on(changeset)
    end

    test "a project without a runner takes no job", ctx do
      Repo.delete!(ctx.runner)

      assert {:error, changeset} =
               Jobs.create_job(ctx.user, ctx.workspace, %{
                 "prompt" => "x",
                 "project_id" => ctx.project.id
               })

      assert %{project_id: ["o projeto precisa de um runner"]} = errors_on(changeset)
    end

    test "with the runner offline the job waits and is handed over when it connects", ctx do
      {:ok, job} =
        Jobs.create_job(ctx.user, ctx.workspace, %{
          "prompt" => "x",
          "project_id" => ctx.project.id
        })

      assert Enum.map(Jobs.queued_for_runner(ctx.runner), & &1.id) == [job.id]
    end
  end
end
