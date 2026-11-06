defmodule PipeMaestro.Projects.ProjectRunnerTest do
  use PipeMaestro.DataCase, async: true

  import PipeMaestro.Fixtures

  alias PipeMaestro.{Audit, Projects, Runners, Tasks}
  alias PipeMaestro.Projects.Project

  setup do
    workspace = workspace_fixture()
    user = member_fixture(workspace)
    {mac, _token} = runner_fixture(workspace, user, %{name: "mac"})
    {server, _token} = runner_fixture(workspace, user, %{name: "servidor"})

    mac =
      with_directories(mac, [
        %{"name" => "app", "git" => true},
        %{"name" => "notas", "git" => false}
      ])

    server = with_directories(server, [%{"name" => "app", "git" => true}])

    %{workspace: workspace, user: user, mac: mac, server: server}
  end

  defp attrs(runner, extra \\ %{}) do
    Map.merge(
      %{
        "name" => "App",
        "runner_id" => runner.id,
        "directory" => "app",
        "setup_command" => "mix deps.get",
        "test_command" => "mix test",
        "copy_paths_text" => "deps\n_build"
      },
      extra
    )
  end

  defp project(ctx, runner \\ nil, extra \\ %{}) do
    {:ok, project} =
      Projects.create_project(ctx.workspace, attrs(runner || ctx.mac, extra))

    project
  end

  describe "a project is a runner and a directory it offers" do
    test "is created with a runner of the workspace that offers the directory", ctx do
      assert {:ok, %Project{} = project} =
               Projects.create_project(ctx.workspace, attrs(ctx.mac))

      assert project.runner_id == ctx.mac.id
      assert project.directory == "app"
      assert Projects.get_project!(ctx.workspace, project.id).runner_id == ctx.mac.id
    end

    test "requires the runner", ctx do
      assert {:error, changeset} =
               Projects.create_project(ctx.workspace, Map.delete(attrs(ctx.mac), "runner_id"))

      assert %{runner_id: [_]} = errors_on(changeset)
    end

    test "refuses a directory the runner does not offer", ctx do
      assert {:error, changeset} =
               Projects.create_project(
                 ctx.workspace,
                 attrs(ctx.server, %{"directory" => "notas"})
               )

      assert %{directory: ["o runner não oferece esse diretório"]} = errors_on(changeset)
    end

    test "refuses a runner of another workspace or a revoked one", ctx do
      other = workspace_fixture()
      {foreign, _token} = runner_fixture(other, member_fixture(other))
      foreign = with_directories(foreign, [%{"name" => "app", "git" => true}])

      assert {:error, changeset} = Projects.create_project(ctx.workspace, attrs(foreign))
      assert %{runner_id: ["não é um runner ativo deste workspace"]} = errors_on(changeset)

      {:ok, revoked} = Runners.revoke_runner(ctx.server)
      assert {:error, changeset} = Projects.create_project(ctx.workspace, attrs(revoked))
      assert %{runner_id: ["não é um runner ativo deste workspace"]} = errors_on(changeset)
    end

    test "the same directory may be a project on another runner, never twice on one", ctx do
      _on_mac = project(ctx, ctx.mac)
      assert {:ok, on_server} = Projects.create_project(ctx.workspace, attrs(ctx.server))
      assert on_server.runner_id == ctx.server.id

      assert {:error, changeset} =
               Projects.create_project(ctx.workspace, attrs(ctx.mac, %{"name" => "Outro"}))

      assert %{directory: ["esse runner já tem um projeto nessa pasta"]} = errors_on(changeset)
    end
  end

  describe "switch_runner/3" do
    test "moves the project to another active runner that offers the directory, audited",
         ctx do
      project = project(ctx)

      assert {:ok, %Project{} = switched} =
               Projects.switch_runner(project, ctx.server.id, ctx.user)

      assert switched.runner_id == ctx.server.id

      assert [event | _] = Audit.list_events(ctx.workspace)
      assert event.action == "project.runner_switched"
      assert event.subject_id == project.id
      assert event.details == %{"from" => ctx.mac.id, "to" => ctx.server.id}
    end

    test "refuses a runner that does not offer the directory", ctx do
      {bare, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: "vazio"})
      project = project(ctx)

      assert {:error, changeset} = Projects.switch_runner(project, bare.id, ctx.user)
      assert %{directory: ["o runner não oferece esse diretório"]} = errors_on(changeset)
      assert Projects.get_project!(ctx.workspace, project.id).runner_id == ctx.mac.id
    end

    test "refuses a runner that already has a project in the directory", ctx do
      project = project(ctx, ctx.mac)
      _on_server = project(ctx, ctx.server, %{"name" => "App no servidor"})

      assert {:error, changeset} = Projects.switch_runner(project, ctx.server.id, ctx.user)
      assert %{directory: ["esse runner já tem um projeto nessa pasta"]} = errors_on(changeset)
    end

    test "tasks already started keep their own runner", ctx do
      project = project(ctx)
      pipeline = pipeline_fixture(ctx.workspace)

      {:ok, task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "T",
          "prompt" => "p",
          "pipeline_id" => pipeline.id,
          "project_id" => project.id
        })

      {:ok, _project} = Projects.switch_runner(project, ctx.server.id, ctx.user)
      assert Tasks.get_task!(ctx.workspace, task.id).runner_id == ctx.mac.id
    end
  end

  describe "runner_choices/1" do
    test "the workspace's active runners that offer the project's directory", ctx do
      {_bare, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: "vazio"})
      project = project(ctx)

      names = project |> Projects.runner_choices() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["mac", "servidor"]

      {:ok, _revoked} = Runners.revoke_runner(ctx.server)
      assert Enum.map(Projects.runner_choices(project), & &1.name) == ["mac"]
    end
  end

  describe "health/2" do
    test "ok, runner offline, directory gone", ctx do
      project = project(ctx)

      assert Projects.health(project, MapSet.new([ctx.mac.id])) == :ok
      assert Projects.health(project, MapSet.new()) == :runner_offline

      _mac = with_directories(ctx.mac, [%{"name" => "notas", "git" => false}])
      project = Projects.get_project!(ctx.workspace, project.id)
      assert Projects.health(project, MapSet.new([ctx.mac.id])) == :directory_gone
    end

    test "a project whose runner was deleted needs a runner", ctx do
      project = project(ctx)
      PipeMaestro.Repo.delete!(ctx.mac)

      project = Projects.get_project!(ctx.workspace, project.id)
      assert project.runner_id == nil
      assert Projects.health(project, MapSet.new()) == :needs_runner
    end
  end

  describe "scratch_context/1" do
    test "a disposable worktree of the project's directory, set up from the project", ctx do
      project = project(ctx)

      assert Projects.scratch_context(project) == %{
               "directory" => "app",
               "scratch" => true,
               "setup" => %{"command" => "mix deps.get", "copy" => ["deps", "_build"]}
             }
    end

    test "with nothing to set up, only the directory and scratch", ctx do
      project = project(ctx, ctx.mac, %{"setup_command" => "", "copy_paths_text" => ""})
      assert Projects.scratch_context(project) == %{"directory" => "app", "scratch" => true}
    end
  end

  describe "recent_tasks/2" do
    test "the project's newest tasks, at most n", ctx do
      project = project(ctx)
      other = project(ctx, ctx.server, %{"name" => "App no servidor"})
      pipeline = pipeline_fixture(ctx.workspace)

      # Timestamps have one-second precision: each task is a second older than the next.
      for {{title, p}, age} <-
            Enum.with_index([{"um", project}, {"dois", project}, {"fora", other}]) do
        {:ok, task} =
          Tasks.create_task(ctx.user, ctx.workspace, %{
            "title" => title,
            "prompt" => "p",
            "pipeline_id" => pipeline.id,
            "project_id" => p.id
          })

        task
        |> Ecto.Changeset.change(inserted_at: DateTime.add(task.inserted_at, age - 10, :second))
        |> PipeMaestro.Repo.update!()
      end

      assert Enum.map(Projects.recent_tasks(project, 5), & &1.title) == ["dois", "um"]
      assert Enum.map(Projects.recent_tasks(project, 1), & &1.title) == ["dois"]
    end
  end
end
