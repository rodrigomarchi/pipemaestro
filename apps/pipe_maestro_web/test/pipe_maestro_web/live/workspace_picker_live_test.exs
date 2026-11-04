defmodule PipeMaestroWeb.WorkspacePickerLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "requires a signed-in user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/workspaces")
  end

  test "goes straight to the only workspace", %{conn: conn} do
    workspace = workspace_fixture()
    user = member_fixture(workspace)

    assert {:error, {:redirect, %{to: to}}} =
             conn |> log_in_user(user) |> live(~p"/workspaces")

    assert to == ~p"/w/#{workspace.slug}"
  end

  test "lists every workspace when there are several", %{conn: conn} do
    first = workspace_fixture(%{name: "Acme"})
    second = workspace_fixture(%{name: "Globex"})
    user = member_fixture(first)
    {:ok, _} = PipeMaestro.Workspaces.add_member(second, user)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/workspaces")

    assert has_element?(view, "#workspace-#{first.slug}")
    assert has_element?(view, "#workspace-#{second.slug}")
  end

  test "explains what to do without any workspace", %{conn: conn} do
    {:ok, _view, html} = conn |> log_in_user(user_fixture()) |> live(~p"/workspaces")
    assert html =~ "ainda não faz parte de nenhum workspace"
  end
end
