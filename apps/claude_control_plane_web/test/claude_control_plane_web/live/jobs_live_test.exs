defmodule ClaudeControlPlaneWeb.JobsLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.Jobs
  alias ClaudeControlPlaneWeb.RunnerStatus

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

  test "is empty at first and offers only online runners", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {online, _token} = runner_fixture(workspace, user, %{name: "ligado"})
    runner_fixture(workspace, user, %{name: "desligado"})
    bring_online(online)

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs")
    assert has_element?(view, "[data-testid=no-jobs]")

    view |> element("[data-testid=new-job]") |> render_click()
    refute has_element?(view, "[data-testid=no-online-runners]")

    options = view |> element("[data-testid=job-runner]") |> render()
    assert options =~ "ligado"
    refute options =~ "desligado"

    render_click(view, "close_new")
    refute has_element?(view, "#new-job-form")
  end

  test "warns when no runner is online", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs")
    view |> element("[data-testid=new-job]") |> render_click()
    assert has_element?(view, "[data-testid=no-online-runners]")
  end

  test "sends a prompt to a runner and opens the job", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user, %{name: "ligado"})
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
      |> form("#new-job-form", job: %{prompt: "diga oi", runner_id: runner.id})
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
end
