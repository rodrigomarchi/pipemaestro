defmodule ClaudeControlPlaneWeb.AppVersionTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # The control plane runs as 2026-11-04.02 in tests (config/test.exs).
  @version "2026-11-04.02"

  test "the public layout shows the control plane's version", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")
    assert has_element?(view, "[data-testid=app-version]", @version)
  end

  test "the workspace layout shows it in the sidebar's footer", %{conn: conn} do
    %{conn: conn, workspace: workspace} = register_and_log_in_member(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/runners")
    assert has_element?(view, "[data-testid=app-version]", @version)
  end

  test "the backoffice layout shows it in the sidebar's footer", %{conn: conn} do
    conn = log_in_operator(conn, operator_fixture())

    {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces")
    assert has_element?(view, "[data-testid=app-version]", @version)
  end
end
