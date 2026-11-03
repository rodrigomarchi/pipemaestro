defmodule ClaudeControlPlaneWeb.RunnersLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.Runners
  alias ClaudeControlPlaneWeb.RunnerStatus

  setup :register_and_log_in_member

  test "explains how to connect when there are no runners", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")
    assert has_element?(view, "[data-testid=no-runners]")

    view |> element("[data-testid=connect-runner]") |> render_click()

    assert view |> element("[data-testid=connect-login-command]") |> render() =~
             "runner.login URL="

    render_click(view, "close_connect")
    refute has_element?(view, "[data-testid=connect-login-command]")
  end

  test "lists the workspace's runners and only those", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} =
      runner_fixture(workspace, user, %{name: "build-01", labels: ["docker"], capacity: 6})

    {:ok, _runner} =
      ClaudeControlPlane.Runners.update_worktree_usage(runner, %{
        "count" => 3,
        "bytes" => 1_610_612_736,
        "free_bytes" => 53_687_091_200
      })

    other = workspace_fixture()
    runner_fixture(other, member_fixture(other), %{name: "alheio"})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    assert has_element?(view, "[data-testid=runner-build-01]")
    assert has_element?(view, "[data-testid=runner-status-build-01]", "Offline")
    assert has_element?(view, "[data-testid=runner-labels-build-01]", "docker")
    assert has_element?(view, "[data-testid=runner-capacity-build-01]", "6")
    assert has_element?(view, "[data-testid=runner-directories-build-01]", "sem raiz")
    assert has_element?(view, "[data-testid=runner-worktrees-build-01]", "3 · 1,5 GB")
    assert has_element?(view, "[data-testid=runner-worktrees-build-01]", "50 GB livres")
    refute has_element?(view, "[data-testid=runner-alheio]")
  end

  test "turns a runner online and back offline live", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, _token} = runner_fixture(workspace, user, %{name: "build-01"})
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    tracker = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, _ref} = RunnerStatus.track(tracker, runner)

    assert eventually(fn ->
             has_element?(view, "[data-testid=runner-status-build-01]", "Online")
           end)

    assert has_element?(view, "[data-testid=online-count]", "1 online")

    Process.exit(tracker, :kill)

    assert eventually(fn ->
             has_element?(view, "[data-testid=runner-status-build-01]", "Offline")
           end)
  end

  test "renames a runner", %{conn: conn, workspace: workspace, user: user} do
    runner_fixture(workspace, user, %{name: "build-01"})
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    view |> element("[data-testid=runner-rename-build-01]") |> render_click()

    assert view |> form("#rename-form", runner: %{name: ""}) |> render_submit() =~
             "não pode ficar em branco"

    html = view |> form("#rename-form", runner: %{name: "Servidor A"}) |> render_submit()

    assert html =~ "Runner renomeado para Servidor A."
    assert has_element?(view, ~s([data-testid="runner-Servidor A"]))
    render_click(view, "open_rename", %{"id" => hd(Runners.list_runners(workspace)).id})
    render_click(view, "close_rename")
    refute has_element?(view, "#rename-form")
  end

  test "revokes a runner and closes its connection", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    {runner, token} = runner_fixture(workspace, user, %{name: "build-01"})
    ClaudeControlPlaneWeb.Endpoint.subscribe(RunnerStatus.socket_id(runner.id))
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")

    assert view |> element("[data-testid=runner-revoke-build-01]") |> render_click() =~
             "Runner build-01 revogado."

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    refute Runners.authenticate_runner(token)
    refute has_element?(view, "[data-testid=runner-build-01]")
  end

  test "the sidebar leads here", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    assert view |> element("[data-testid=sidebar-runners]") |> render() =~
             ~s(href="/w/#{workspace.slug}/runners")
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
