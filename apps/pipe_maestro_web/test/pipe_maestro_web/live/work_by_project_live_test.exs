defmodule PipeMaestroWeb.WorkByProjectLiveTest do
  use PipeMaestroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Projects, Runners, Tasks}
  alias PipeMaestroWeb.RunnerStatus

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}],
          capabilities: ["scratch"]
        })
      )

    {:ok, app} =
      Projects.create_project(workspace, %{
        "name" => "App",
        "runner_id" => runner.id,
        "directory" => "app",
        "setup_command" => "mix deps.get",
        "test_command" => "mix test"
      })

    {:ok, notes} =
      Projects.create_project(workspace, %{
        "name" => "Notas",
        "runner_id" => runner.id,
        "directory" => "notas"
      })

    %{
      runner: runner,
      app: app,
      notes: notes,
      pipeline: pipeline_fixture(workspace, %{"name" => "Duas etapas"})
    }
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

  defp create_task(ctx, project, title \\ "Corrigir login") do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => title,
        "prompt" => "O botão não responde",
        "pipeline_id" => ctx.pipeline.id,
        "project_id" => project.id
      })

    task
  end

  describe "a new task" do
    test "chooses only the project", ctx do
      bring_online(ctx.runner)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      view |> element("[data-testid=new-task]") |> render_click()

      refute has_element?(view, "[data-testid=task-runner]")
      refute has_element?(view, "[data-testid=task-directory]")
      projects = view |> element("[data-testid=task-project]") |> render()
      assert projects =~ "App"
      assert projects =~ "Notas"

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#new-task-form",
          task: %{
            title: "Corrigir login",
            prompt: "O botão não responde",
            pipeline_id: ctx.pipeline.id,
            project_id: ctx.app.id
          }
        )
        |> render_submit()

      [task] = Tasks.list_tasks(ctx.workspace)
      assert path == "/w/#{ctx.workspace.slug}/tasks/#{task.id}"
      assert {task.project_id, task.runner_id} == {ctx.app.id, ctx.runner.id}
    end

    test "the shortcut from the projects opens the form with the project", ctx do
      {:ok, view, _html} =
        live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks?project_id=#{ctx.app.id}")

      assert has_element?(
               view,
               "[data-testid=task-project] option[selected][value='#{ctx.app.id}']"
             )
    end

    test "a project whose runner is offline is accepted, with a warning", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      view |> element("[data-testid=new-task]") |> render_click()

      view |> form("#new-task-form", task: %{project_id: ctx.app.id}) |> render_change()
      assert has_element?(view, "[data-testid=task-project-offline]", "mac")
    end
  end

  describe "a task" do
    test "shows its project, linked, with the snapshot it keeps", ctx do
      task = create_task(ctx, ctx.app)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      assert has_element?(view, "[data-testid=task-project]", "App")
      assert view |> element("[data-testid=task-project] a") |> render() =~ "/projects/"
      assert has_element?(view, "[data-testid=task-project-snapshot]", "mix deps.get")
      assert has_element?(view, "[data-testid=task-project-snapshot]", "mix test")
    end

    test "waits for its runner while it is offline", ctx do
      task = create_task(ctx, ctx.app)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")
      assert has_element?(view, "[data-testid=task-waiting-runner]", "mac")

      bring_online(ctx.runner)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")
      refute has_element?(view, "[data-testid=task-waiting-runner]")
    end
  end

  describe "a job on its own" do
    test "chooses only the project; one without git is disabled with the reason", ctx do
      bring_online(ctx.runner)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/jobs")
      view |> element("[data-testid=new-job]") |> render_click()

      refute has_element?(view, "[data-testid=job-runner]")
      projects = view |> element("[data-testid=job-project]") |> render()
      assert projects =~ "App"
      assert projects =~ ~r/<option disabled[^>]*>Notas \([^)]*git/

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#new-job-form", job: %{prompt: "diga oi", project_id: ctx.app.id})
        |> render_submit()

      [job] = Jobs.list_jobs(ctx.workspace)
      assert path == "/w/#{ctx.workspace.slug}/jobs/#{job.id}"
      assert job.project_id == ctx.app.id
      assert job.context["scratch"] == true
    end

    test "the shortcut from the projects opens the form with the project", ctx do
      {:ok, view, _html} =
        live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/jobs?project_id=#{ctx.app.id}")

      assert has_element?(
               view,
               "[data-testid=job-project] option[selected][value='#{ctx.app.id}']"
             )
    end

    test "a project whose runner is offline is accepted, with a warning", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/jobs")
      view |> element("[data-testid=new-job]") |> render_click()

      view |> form("#new-job-form", job: %{project_id: ctx.app.id}) |> render_change()
      assert has_element?(view, "[data-testid=job-project-offline]", "mac")
    end
  end

  describe "the board" do
    test "filters by project and shows each card's project", ctx do
      a = create_task(ctx, ctx.app, "No app")
      b = create_task(ctx, ctx.notes, "Nas notas")

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}?aba=tarefas")

      assert has_element?(
               view,
               "[data-testid=board-task-#{a.id}] [data-testid=board-card-project]",
               "App"
             )

      view |> form("#board-filters", filters: %{project_id: ctx.notes.id}) |> render_change()
      assert_patch(view, ~p"/w/#{ctx.workspace.slug}?aba=tarefas&project_id=#{ctx.notes.id}")
      refute has_element?(view, "[data-testid=board-task-#{a.id}]")
      assert has_element?(view, "[data-testid=board-task-#{b.id}]")
      refute has_element?(view, "[data-testid=board-filter-directory]")
      assert has_element?(view, "[data-testid=board-filter-project]")
    end
  end

  describe "usage" do
    test "sums the cost by project", ctx do
      task = create_task(ctx, ctx.app)
      [stage_run | _] = Tasks.get_task!(ctx.workspace, task.id).stage_runs
      {:ok, _} = Jobs.mark_started(ctx.runner, stage_run.job.id)

      {:ok, _} =
        Jobs.finish_job(ctx.runner, stage_run.job.id, %{
          "status" => "succeeded",
          "cost_usd" => 0.5,
          "structured_output" => %{"status" => "ok", "resumo" => "ok"},
          "artifact" => "# a"
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/usage")
      assert has_element?(view, "[data-testid=usage-by-project]", "App")
    end
  end
end
