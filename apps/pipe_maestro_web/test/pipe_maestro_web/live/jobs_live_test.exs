defmodule PipeMaestroWeb.JobsLiveTest do
  use PipeMaestroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PipeMaestro.Jobs
  alias PipeMaestroWeb.RunnerStatus

  setup :register_and_log_in_member

  # Tracks the runner online the way its channel does, from a process that
  # lives for the test.
  defp bring_online(runner) do
    test_pid = self()

    pid =
      spawn_link(fn ->
        {:ok, _ref} = RunnerStatus.track(self(), runner)
        send(test_pid, :tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :tracked
    pid
  end

  # A runner with a git directory, able to run a disposable worktree.
  defp scratch_runner(workspace, user, name) do
    {runner, _token} = runner_fixture(workspace, user, %{name: name})

    {:ok, runner} =
      PipeMaestro.Runners.record_hello(
        runner,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}],
          capabilities: ["scratch"]
        })
      )

    runner
  end

  test "is empty at first and offers the projects", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    project_fixture(scratch_runner(workspace, user, "ligado"), "app", %{"name" => "App"})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs")
    assert has_element?(view, "[data-testid=no-jobs]")

    view |> element("[data-testid=new-job]") |> render_click()
    refute has_element?(view, "[data-testid=job-no-projects]")
    assert view |> element("[data-testid=job-project]") |> render() =~ "App · ligado:app"

    render_click(view, "close_new")
    refute has_element?(view, "#new-job-form")
  end

  test "points to the projects when there are none", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs")
    view |> element("[data-testid=new-job]") |> render_click()
    assert has_element?(view, "[data-testid=job-no-projects]")
  end

  test "sends a prompt to a project and opens the job", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    runner = scratch_runner(workspace, user, "ligado")
    project = project_fixture(runner, "app")
    bring_online(runner)
    Jobs.subscribe({:runner, runner.id})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs")
    view |> element("[data-testid=new-job]") |> render_click()

    view
    |> form("#new-job-form", job: %{prompt: ""})
    |> render_submit()

    assert has_element?(view, "#new-job-form", "escreva o que o agente deve fazer")

    {:error, {:live_redirect, %{to: "/w/" <> _ = path}}} =
      view
      |> form("#new-job-form", job: %{prompt: "diga oi", project_id: project.id})
      |> render_submit()

    assert_receive {:job_assign, job}
    assert path == "/w/#{workspace.slug}/jobs/#{job.id}"
  end

  test "lists the workspace's jobs and updates them live", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user)
    job = job_fixture(runner, user, %{"prompt" => "primeira linha\nsegunda"})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs")
    assert has_element?(view, "[data-testid=job-link-#{job.id}]", "primeira linha")
    refute has_element?(view, "[data-testid=job-link-#{job.id}]", "segunda")
    assert has_element?(view, "[data-testid=job-status-#{job.id}]", "Na fila")

    {:ok, _} = Jobs.mark_started(runner, job.id)
    assert render(view) =~ "Executando"

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{
        "status" => "succeeded",
        "duration_ms" => 65_000,
        "cost_usd" => 0.01234
      })

    assert has_element?(view, "[data-testid=job-status-#{job.id}]", "Concluído")
    assert render(view) =~ "1 min 05 s"
    assert render(view) =~ "US$ 0.0123"
  end

  test "the jobs are a column of cards, 30 at a time, the running one called out", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user)
    for n <- 1..31, do: job_fixture(runner, user, %{"prompt" => "tarefa #{n}"})
    [newest | _] = listed = Jobs.list_jobs(workspace)
    oldest = List.last(listed)
    {:ok, _} = Jobs.mark_started(runner, newest.id)

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs")
    refute has_element?(view, "table")
    assert has_element?(view, "[data-testid=jobs] li[data-testid=job-row-#{newest.id}]")
    assert has_element?(view, "[data-testid=job-row-#{newest.id}].border-info-400")

    refute has_element?(view, "[data-testid=job-row-#{oldest.id}]")
    view |> element("[data-testid=jobs-load-more]") |> render_click()
    assert has_element?(view, "[data-testid=job-row-#{oldest.id}]")
    refute has_element?(view, "[data-testid=jobs-load-more]")
  end
end
