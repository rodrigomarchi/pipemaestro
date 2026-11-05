defmodule PipeMaestroWeb.ProjectLiveRunnerTest do
  use PipeMaestroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Audit, Jobs, Projects, Proposals, Repo, Runners, Tasks}
  alias PipeMaestroWeb.RunnerStatus

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {mac, _token} = runner_fixture(workspace, user, %{name: "mac"})
    {server, _token} = runner_fixture(workspace, user, %{name: "servidor"})

    {:ok, mac} =
      Runners.record_hello(
        mac,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}],
          capabilities: ["scratch"]
        })
      )

    server = with_directories(server, [%{"name" => "app", "git" => true}])
    %{mac: mac, server: server}
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

  defp project(ctx, runner, attrs \\ %{}) do
    {:ok, project} =
      Projects.create_project(
        ctx.workspace,
        Map.merge(%{"name" => "App", "runner_id" => runner.id, "directory" => "app"}, attrs),
        ctx.user
      )

    project
  end

  describe "the form" do
    test "picks a runner, then one of the directories it offers", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects/new")

      runners = view |> element("[data-testid=project-runner]") |> render()
      assert runners =~ "mac"
      assert runners =~ "servidor"
      refute view |> element("[data-testid=project-directory]") |> render() =~ "notas"

      view |> form("#project-form", project: %{runner_id: ctx.mac.id}) |> render_change()
      directories = view |> element("[data-testid=project-directory]") |> render()
      assert directories =~ "app"
      assert directories =~ "notas"

      view |> form("#project-form", project: %{runner_id: ctx.server.id}) |> render_change()
      directories = view |> element("[data-testid=project-directory]") |> render()
      assert directories =~ "app"
      refute directories =~ "notas"

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#project-form",
          project: %{name: "App", runner_id: ctx.server.id, directory: "app"}
        )
        |> render_submit()

      assert path == "/w/#{ctx.workspace.slug}/projects"
      assert [%{runner_id: runner_id}] = Projects.list_projects(ctx.workspace)
      assert runner_id == ctx.server.id
    end

    test "a project without a runner is refused", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects/new")

      html =
        view
        |> form("#project-form", project: %{name: "App", runner_id: ""})
        |> render_submit()

      assert html =~ "escolha o runner do projeto"
      assert Projects.list_projects(ctx.workspace) == []
    end

    test "analyse with AI asks the agent about the directory and opens the proposal", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects/new")

      view
      |> form("#project-form", project: %{runner_id: ctx.mac.id, directory: "app"})
      |> render_change()

      {:error, {:live_redirect, %{to: path}}} =
        view |> element("[data-testid=project-analyze]") |> render_click()

      [job] = Proposals.list_recent(ctx.workspace)
      assert Proposals.kind(job) == "project"
      assert path == "/w/#{ctx.workspace.slug}/proposals/#{job.id}"
      assert Projects.list_projects(ctx.workspace) == []
    end

    test "the project's runner can be switched for another that offers the directory", ctx do
      project = project(ctx, ctx.mac)
      {bare, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: "vazio"})

      {:ok, view, _html} =
        live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects/#{project.id}/edit")

      choices = view |> element("[data-testid=project-switch-runner]") |> render()
      assert choices =~ "servidor"
      refute choices =~ bare.name

      view
      |> form("#project-switch-runner-form", switch: %{runner_id: ctx.server.id})
      |> render_submit()

      assert Projects.get_project!(ctx.workspace, project.id).runner_id == ctx.server.id
      assert [%{action: "project.runner_switched"} | _] = Audit.list_events(ctx.workspace)
    end
  end

  describe "the proposal of a project" do
    test "fills the form for review; nothing is saved until Save", ctx do
      {:ok, job} =
        Proposals.request("project", ctx.user, ctx.workspace, %{
          "runner_id" => ctx.mac.id,
          "directory" => "app"
        })

      {:ok, _} = Jobs.mark_started(ctx.mac, job.id)

      {:ok, _} =
        Jobs.finish_job(ctx.mac, job.id, %{
          "status" => "succeeded",
          "structured_output" => %{
            "analise" => "Um app **Phoenix**.",
            "verificacoes" => [%{"comando" => "mix test", "passou" => true}],
            "projeto" => %{"nome" => "App", "teste" => "mix test", "copy_paths" => ["deps"]}
          }
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/proposals/#{job.id}")
      assert has_element?(view, "[data-testid=proposal-project-form]")
      assert Projects.list_projects(ctx.workspace) == []

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#proposal-project-form", project: %{lint_command: "mix credo"})
        |> render_submit()

      assert path == "/w/#{ctx.workspace.slug}/projects"

      assert [%{name: "App", lint_command: "mix credo", directory: "app"} = saved] =
               Projects.list_projects(ctx.workspace)

      assert saved.runner_id == ctx.mac.id
      assert saved.copy_paths == ["deps"]
    end
  end

  describe "the list" do
    test "shows the runner and whether it is online, with shortcuts and recent tasks", ctx do
      project = project(ctx, ctx.mac)
      pipeline = pipeline_fixture(ctx.workspace)

      {:ok, _task} =
        Tasks.create_task(ctx.user, ctx.workspace, %{
          "title" => "Corrigir login",
          "prompt" => "p",
          "pipeline_id" => pipeline.id,
          "project_id" => project.id
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects")
      assert has_element?(view, "[data-testid=project-runner-app]", "mac")
      assert has_element?(view, "[data-testid=project-status-app]", "offline")
      assert has_element?(view, "[data-testid=project-recent-tasks-app]", "Corrigir login")

      assert view |> element("[data-testid=project-new-task-app]") |> render() =~
               "/w/#{ctx.workspace.slug}/tasks?project_id=#{project.id}"

      assert view |> element("[data-testid=project-new-job-app]") |> render() =~
               "/w/#{ctx.workspace.slug}/jobs?project_id=#{project.id}"

      bring_online(ctx.mac)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects")
      assert has_element?(view, "[data-testid=project-status-app]", "online")
    end

    test "warns when the project needs a runner", ctx do
      _app = project(ctx, ctx.mac)
      Repo.delete!(ctx.mac)

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects")
      assert has_element?(view, "[data-testid=project-needs-runner-app]")
      refute has_element?(view, "[data-testid=project-new-task-app]")
    end

    test "warns when the runner no longer offers the directory", ctx do
      _app = project(ctx, ctx.server)
      with_directories(ctx.server, [])

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/projects")
      assert has_element?(view, "[data-testid=project-directory-gone-app]")
    end
  end
end
