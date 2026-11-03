defmodule ClaudeControlPlaneWeb.RunnerLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.{Jobs, Runners}

  setup :register_and_log_in_member

  test "shows a runner: agent, directories, worktrees and its jobs, live", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    {:ok, runner} =
      Runners.record_hello(
        runner,
        hello_fixture(%{
          directories: [%{"name" => "app", "git" => true}, %{"name" => "notas", "git" => false}],
          agent: %{"cli_version" => "2.1.317", "auth" => "api_key"}
        })
      )

    {:ok, _} =
      Runners.update_worktree_usage(runner, %{"count" => 2, "bytes" => 2048, "free_bytes" => nil})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    {:error, {:live_redirect, %{to: path}}} =
      view |> element("[data-testid=runner-link-mac]") |> render_click()

    assert path == "/w/#{workspace.slug}/runners/#{runner.id}"

    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "[data-testid=runner-detail-agent]", "2.1.317")
    assert has_element?(view, "[data-testid=runner-detail-agent]", "chave de API")
    assert has_element?(view, "[data-testid=runner-detail-directories]", "notas")
    assert has_element?(view, "[data-testid=runner-detail-worktrees]", "2 · 2,0 KB")
    assert has_element?(view, "[data-testid=runner-no-jobs]")

    job = job_fixture(runner, user, %{"prompt" => "investigue o login"})
    assert has_element?(view, "[data-testid=runner-job-#{job.id}]", "investigue o login")
    assert has_element?(view, "[data-testid=runner-job-#{job.id}]", "Na fila")

    {:ok, _} = Jobs.mark_started(runner, job.id)
    assert has_element?(view, "[data-testid=runner-job-#{job.id}]", "Executando")
  end

  test "an admin revokes the runner from its page and goes back to the list", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, token} = runner_fixture(workspace, user, %{name: "antigo"})

    ClaudeControlPlaneWeb.Endpoint.subscribe(
      ClaudeControlPlaneWeb.RunnerStatus.socket_id(runner.id)
    )

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}")

    {:ok, list, html} =
      view
      |> element("[data-testid=runner-detail-revoke]")
      |> render_click()
      |> follow_redirect(conn, ~p"/w/#{workspace.slug}/runners")

    assert html =~ "Runner antigo revogado."
    refute has_element?(list, "[data-testid=runner-antigo]")
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    refute Runners.authenticate_runner(token)
  end

  test "another workspace's runner is not found", %{conn: conn, workspace: workspace} do
    other = workspace_fixture()
    {runner, _token} = runner_fixture(other, member_fixture(other))

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/w/#{workspace.slug}/runners/#{runner.id}")
    end
  end
end
