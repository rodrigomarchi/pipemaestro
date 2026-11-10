defmodule PipeMaestro.Tasks.TaskFromProjectTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.Integrations.IssueSource
  alias PipeMaestro.{Jobs, Projects, Repo, Tasks}
  alias PipeMaestro.Projects.Project

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    runner =
      with_directories(runner, [
        %{"name" => "app", "git" => true},
        %{"name" => "notas", "git" => false}
      ])

    pipeline = pipeline_fixture(workspace)

    {:ok, project} =
      Projects.create_project(
        workspace,
        %{
          "name" => "App",
          "runner_id" => runner.id,
          "directory" => "app",
          "setup_command" => "mix deps.get",
          "test_command" => "mix test",
          "copy_paths_text" => "deps"
        }
      )

    %{workspace: workspace, user: user, runner: runner, pipeline: pipeline, project: project}
  end

  defp params(ctx, extra \\ %{}) do
    Map.merge(
      %{
        "title" => "Corrigir o login",
        "prompt" => "O botão não responde",
        "pipeline_id" => ctx.pipeline.id,
        "project_id" => ctx.project.id
      },
      extra
    )
  end

  describe "create_task/4 from a project" do
    test "takes the runner, the directory, git and the snapshot from the project", ctx do
      assert {:ok, task} = Tasks.create_task(ctx.user, ctx.workspace, params(ctx))

      assert task.project_id == ctx.project.id
      assert task.runner_id == ctx.runner.id
      assert task.directory == "app"
      assert task.git == true
      assert task.project == Project.snapshot(ctx.project)

      [stage_run | _] = Tasks.get_task!(ctx.workspace, task.id).stage_runs
      assert stage_run.job.runner_id == ctx.runner.id
      assert stage_run.job.project_id == ctx.project.id
    end

    test "a runner and a directory from the form are ignored: the project decides", ctx do
      {other, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: "outro"})
      other = with_directories(other, [%{"name" => "lib", "git" => true}])

      assert {:ok, task} =
               Tasks.create_task(
                 ctx.user,
                 ctx.workspace,
                 params(ctx, %{"runner_id" => other.id, "directory" => "lib"})
               )

      assert {task.runner_id, task.directory} == {ctx.runner.id, "app"}
    end

    test "every task needs a project", ctx do
      assert {:error, changeset} =
               Tasks.create_task(ctx.user, ctx.workspace, Map.delete(params(ctx), "project_id"))

      assert %{project_id: ["escolha um projeto"]} = errors_on(changeset)
    end

    test "refuses a project of another workspace", ctx do
      other = workspace_fixture()
      other_user = member_fixture(other)
      {runner, _token} = runner_fixture(other, other_user)
      with_directories(runner, [%{"name" => "app", "git" => true}])

      {:ok, foreign} =
        Projects.create_project(other, %{
          "name" => "Fora",
          "runner_id" => runner.id,
          "directory" => "app"
        })

      assert {:error, changeset} =
               Tasks.create_task(
                 ctx.user,
                 ctx.workspace,
                 params(ctx, %{"project_id" => foreign.id})
               )

      assert %{project_id: ["o projeto não existe mais"]} = errors_on(changeset)
    end

    test "a project without a runner takes no task", ctx do
      Repo.delete!(ctx.runner)

      assert {:error, changeset} = Tasks.create_task(ctx.user, ctx.workspace, params(ctx))
      assert %{project_id: ["o projeto precisa de um runner"]} = errors_on(changeset)
    end

    test "a project whose runner no longer offers the directory takes no task", ctx do
      with_directories(ctx.runner, [%{"name" => "notas", "git" => false}])

      assert {:error, changeset} = Tasks.create_task(ctx.user, ctx.workspace, params(ctx))
      assert %{directory: ["o runner não oferece esse diretório"]} = errors_on(changeset)
    end

    test "a directory without git gets no worktree", ctx do
      {:ok, notes} =
        Projects.create_project(ctx.workspace, %{
          "name" => "Notas",
          "runner_id" => ctx.runner.id,
          "directory" => "notas"
        })

      assert {:ok, task} =
               Tasks.create_task(
                 ctx.user,
                 ctx.workspace,
                 params(ctx, %{"project_id" => notes.id})
               )

      assert task.git == false
    end
  end

  describe "a runner offline" do
    test "the task is created and its first job waits for the runner", ctx do
      assert {:ok, task} = Tasks.create_task(ctx.user, ctx.workspace, params(ctx))

      [stage_run | _] = Tasks.get_task!(ctx.workspace, task.id).stage_runs
      assert stage_run.job.status == :queued
      assert Enum.map(Jobs.queued_for_runner(ctx.runner), & &1.id) == [stage_run.job.id]

      assert Tasks.waiting_for_runner?(task, MapSet.new())
      refute Tasks.waiting_for_runner?(task, MapSet.new([ctx.runner.id]))
    end

    test "a task whose job already started is not waiting", ctx do
      {:ok, task} = Tasks.create_task(ctx.user, ctx.workspace, params(ctx))
      [stage_run | _] = Tasks.get_task!(ctx.workspace, task.id).stage_runs
      {:ok, _job} = Jobs.mark_started(ctx.runner, stage_run.job.id)

      refute Tasks.waiting_for_runner?(Tasks.get_task!(ctx.workspace, task.id), MapSet.new())
    end
  end

  describe "list_tasks/2" do
    test "filters by project", ctx do
      {other_runner, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: "servidor"})
      other_runner = with_directories(other_runner, [%{"name" => "app", "git" => true}])

      {:ok, other} =
        Projects.create_project(ctx.workspace, %{
          "name" => "App no servidor",
          "runner_id" => other_runner.id,
          "directory" => "app"
        })

      {:ok, here} = Tasks.create_task(ctx.user, ctx.workspace, params(ctx, %{"title" => "aqui"}))

      {:ok, _there} =
        Tasks.create_task(
          ctx.user,
          ctx.workspace,
          params(ctx, %{"title" => "lá", "project_id" => other.id})
        )

      assert [%{id: id}] = Tasks.list_tasks(ctx.workspace, %{"project_id" => ctx.project.id})
      assert id == here.id
      assert Tasks.list_tasks(ctx.workspace, %{"project_id" => "não é uuid"}) == []
    end
  end

  describe "duplicate and rerun" do
    test "duplicate_params/1 names the project", ctx do
      {:ok, task} = Tasks.create_task(ctx.user, ctx.workspace, params(ctx))

      assert Tasks.duplicate_params(task) == %{
               "title" => "Corrigir o login",
               "prompt" => "O botão não responde",
               "pipeline_id" => ctx.pipeline.id,
               "project_id" => ctx.project.id
             }
    end

    test "rerun/2 of a task whose project was deleted explains it", ctx do
      {:ok, task} = Tasks.create_task(ctx.user, ctx.workspace, params(ctx))
      {:ok, _} = Tasks.cancel_task(task)
      {:ok, _} = Projects.delete_project(ctx.project)

      task = Tasks.get_task!(ctx.workspace, task.id)
      assert task.directory == "app"
      assert task.runner_id == ctx.runner.id
      assert task.project["name"] == "App"

      assert {:error, changeset} = Tasks.rerun(ctx.user, task)
      assert %{project_id: ["o projeto não existe mais"]} = errors_on(changeset)
    end
  end

  describe "create_from_item/3" do
    setup ctx do
      PipeMaestro.FakeForgejo.start()

      {:ok, repo} =
        PipeMaestro.Integrations.link_repo(
          connection_fixture(ctx.workspace),
          ctx.user,
          %{"full_name" => "acme/app", "project_id" => ctx.project.id},
          "https://pm.test/hook"
        )

      target = %{
        mode: "task",
        acting_user_id: ctx.user.id,
        pipeline_id: ctx.pipeline.id,
        project_id: ctx.project.id
      }

      %{repo: Repo.preload(repo, :project), target: target}
    end

    @issue %{
      title: "Botão quebrado",
      body: "Nada acontece.",
      url: "https://forge.test/acme/app/issues/9",
      number: 9
    }

    test "starts the task on the project's runner", ctx do
      assert {:ok, task} =
               Tasks.create_from_item(
                 ctx.workspace,
                 IssueSource.item(ctx.repo, @issue),
                 ctx.target
               )

      assert task.project_id == ctx.project.id
      assert task.runner_id == ctx.runner.id
      assert task.source_url == "https://forge.test/acme/app/issues/9"
    end

    test "a project without a runner cannot start it", ctx do
      Repo.delete!(ctx.runner)
      repo = Repo.preload(ctx.repo, :project, force: true)

      assert {:error, changeset} =
               Tasks.create_from_item(ctx.workspace, IssueSource.item(repo, @issue), ctx.target)

      assert %{project_id: ["o projeto precisa de um runner"]} = errors_on(changeset)
    end
  end
end
