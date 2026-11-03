defmodule ClaudeControlPlaneWeb.BoardLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlaneWeb.Demo

  setup :register_and_log_in_member

  test "renders every stage with its tasks", %{conn: conn, workspace: workspace} do
    {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}")

    for stage <- Demo.stages(), do: assert(html =~ stage.name)
    for task <- Demo.tasks(), do: assert(has_element?(view, "#task-#{task.id}"))
  end

  test "lists pending decisions", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    for decision <- Demo.decisions(), do: assert(has_element?(view, "#decision-#{decision.id}"))
  end

  test "deciding removes the decision and confirms it", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")
    [decision | _] = Demo.decisions()
    [option | _] = decision.options

    view
    |> element("#decision-#{decision.id} button", option)
    |> render_click()

    refute has_element?(view, "#decision-#{decision.id}")
    assert render(view) =~ "Decisão registrada: #{option}"
  end

  test "shows the empty state once every decision is taken", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    for decision <- Demo.decisions() do
      view |> element("#decision-#{decision.id} button", hd(decision.options)) |> render_click()
    end

    assert render(view) =~ "Nenhuma decisão pendente"
  end

  test "explains where new tasks come from", %{conn: conn, workspace: workspace} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    assert view |> element("button", "Nova tarefa") |> render_click() =~ "issues do GitHub"
  end

  test "shows the signed-in user and the workspace", %{conn: conn, workspace: workspace} do
    {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}")

    assert html =~ "Ana Lima"
    assert html =~ "Acme Engineering"
  end

  test "a workspace the user does not belong to is refused", %{conn: conn} do
    other = workspace_fixture()

    assert {:error, {:redirect, %{to: "/workspaces", flash: %{"error" => _}}}} =
             live(conn, ~p"/w/#{other.slug}")
  end

  test "an unknown workspace is refused", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/workspaces"}}} = live(conn, ~p"/w/nao-existe")
  end

  test "the switcher lists every workspace of the user", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    other = workspace_fixture(%{name: "Globex"})
    {:ok, _} = ClaudeControlPlane.Workspaces.add_member(other, user)

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    assert has_element?(view, ~s(#workspace-switcher a[href="/w/#{other.slug}"]))
  end

  test "a revoked session leaves the board", %{conn: conn, workspace: workspace, user: user} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    ClaudeControlPlaneWeb.UserAuth.disconnect_user(user)

    assert_redirect(view, ~p"/login")
  end

  test "anonymous visitors are sent to sign in", %{workspace: workspace} do
    conn = get(build_conn(), ~p"/w/#{workspace.slug}")
    assert redirected_to(conn) == ~p"/login"
  end

  test "shows the workspace's real runners, live", %{conn: conn, workspace: workspace, user: user} do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")
    assert has_element?(view, "[data-testid=board-no-runners]")

    {_runner, _token} = runner_fixture(workspace, user, %{name: "build-01"})
    ClaudeControlPlaneWeb.RunnerStatus.notify_changed(workspace.id)

    assert render(view) =~ "build-01"
    assert has_element?(view, "[data-testid=board-runner-status-build-01]", "Offline")
  end
end
