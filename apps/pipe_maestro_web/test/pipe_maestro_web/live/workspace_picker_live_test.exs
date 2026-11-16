defmodule PipeMaestroWeb.WorkspacePickerLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Workspaces

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
    {:ok, _} = Workspaces.add_member(second, user)

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/workspaces")

    assert has_element?(view, "#workspace-#{first.slug}")
    assert has_element?(view, "#workspace-#{second.slug}")
  end

  test "without any workspace, goes on to create one", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/workspaces/new"}}} =
             conn |> log_in_user(user_fixture()) |> live(~p"/workspaces")
  end

  test "without any workspace and past the plan's limit, tells whom to ask", %{conn: conn} do
    user = user_fixture()

    for n <- 1..3 do
      {:ok, workspace} = Workspaces.create_owned_workspace(user, %{"name" => "Fora #{n}"})
      :ok = Workspaces.remove_member(workspace, user)
    end

    {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/workspaces")
    assert has_element?(view, ~s([data-testid="no-workspaces"]))
    assert html =~ "Fale com o suporte"
  end

  test "asked to choose, lists even a single workspace and offers a new one", %{conn: conn} do
    user = user_fixture()
    {:ok, workspace} = Workspaces.create_owned_workspace(user, %{"name" => "Único"})

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/workspaces?choose=1")
    assert has_element?(view, ~s([data-testid="workspace-card-#{workspace.slug}"]))
    assert has_element?(view, ~s([data-testid="picker-new-workspace"]))
  end

  test "offers a new workspace while the plan allows one", %{conn: conn} do
    user = user_fixture()
    for n <- 1..2, do: {:ok, _} = Workspaces.create_owned_workspace(user, %{"name" => "T #{n}"})

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/workspaces")
    assert has_element?(view, ~s(a[data-testid="picker-new-workspace"][href="/workspaces/new"]))

    {:ok, _} = Workspaces.create_owned_workspace(user, %{"name" => "T 3"})
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/workspaces")
    refute has_element?(view, ~s([data-testid="picker-new-workspace"]))
  end
end
