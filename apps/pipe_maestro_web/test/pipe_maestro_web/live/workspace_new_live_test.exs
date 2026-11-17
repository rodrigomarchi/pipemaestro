defmodule PipeMaestroWeb.WorkspaceNewLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Workspaces

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "requires a signed-in user" do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/workspaces/new")
  end

  test "the first workspace is the second step of signing up", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")
    assert has_element?(view, ~s([data-testid="workspace-new-stepper"]))
  end

  test "someone who already has a workspace can go back to them", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")
    refute has_element?(view, ~s([data-testid="workspace-new-back"]))

    {:ok, _} = Workspaces.create_owned_workspace(user, %{"name" => "Primeiro"})
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")

    assert has_element?(
             view,
             ~s(a[data-testid="workspace-new-back"][href="/workspaces?choose=1"])
           )

    refute has_element?(view, ~s([data-testid="workspace-new-stepper"]))
  end

  test "shows the address that the name gives", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")

    view
    |> form("#workspace-new-form", workspace: %{name: "Acme Engenharia"})
    |> render_change()

    assert view |> element(~s([data-testid="workspace-new-slug-preview"])) |> render() =~
             "/w/acme-engenharia"
  end

  test "points out an address already in use", %{conn: conn} do
    taken = workspace_fixture()
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")

    html =
      view
      |> form("#workspace-new-form", workspace: %{name: "Outra", slug: taken.slug})
      |> render_change()

    assert html =~ "já está em uso"
  end

  test "creates a Free beta workspace and opens it", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")

    assert {:error, {:redirect, %{to: "/w/acme"}}} =
             view |> form("#workspace-new-form", workspace: %{name: "Acme"}) |> render_submit()

    [workspace] = Workspaces.list_workspaces_for_user(user)
    assert workspace.plan == :free_beta
    assert Workspaces.role(workspace, user) == :admin
  end

  test "past the plan's limit, goes back to the workspaces", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")
    for n <- 1..3, do: {:ok, _} = Workspaces.create_owned_workspace(user, %{"name" => "T #{n}"})

    {:ok, picker} =
      view
      |> form("#workspace-new-form", workspace: %{name: "Mais um"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/workspaces")

    assert html_response(picker, 200) =~ "Você chegou ao limite de 3 workspaces do plano Free."
    assert length(Workspaces.list_workspaces_for_user(user)) == 3

    assert {:error, {:redirect, %{to: "/workspaces"}}} = live(conn, ~p"/workspaces/new")
  end
end
