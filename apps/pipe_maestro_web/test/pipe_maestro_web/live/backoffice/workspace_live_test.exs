defmodule PipeMaestroWeb.Backoffice.WorkspaceLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Workspaces

  setup :register_and_log_in_operator

  describe "index" do
    test "lists workspaces with their member count", %{conn: conn} do
      workspace = workspace_fixture(%{name: "Acme"})
      member_fixture(workspace)

      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces")

      assert view |> element("#workspace-#{workspace.id}") |> render() =~ "Acme"
    end

    test "creates a workspace and opens it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/new")

      assert view
             |> form("#workspace-form", workspace: %{name: "", slug: ""})
             |> render_change() =~ "não pode ficar em branco"

      {:ok, _show, html} =
        view
        |> form("#workspace-form", workspace: %{name: "Globex Corp", slug: ""})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Workspace Globex Corp criado."
      assert [%{slug: "globex-corp"}] = Workspaces.list_workspaces()
    end

    test "shows errors from an invalid workspace", %{conn: conn} do
      workspace_fixture(%{slug: "taken"})
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/new")

      assert view
             |> form("#workspace-form", workspace: %{name: "Outra", slug: "taken"})
             |> render_submit() =~ "já está em uso"
    end

    test "edits a workspace", %{conn: conn} do
      workspace = workspace_fixture()
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}/edit")

      assert view
             |> form("#workspace-form", workspace: %{slug: "Inválido!"})
             |> render_submit() =~ "use letras minúsculas"

      assert view
             |> form("#workspace-form", workspace: %{runner_log_retention_days: "91"})
             |> render_submit() =~ "use de 0 a 90 dias"

      html =
        view
        |> form("#workspace-form",
          workspace: %{
            name: "Renomeado",
            slug: "renomeado",
            max_running_tasks: "3",
            runner_log_retention_days: "0"
          }
        )
        |> render_submit()

      assert_patch(view, ~p"/backoffice/workspaces")
      assert html =~ "Workspace Renomeado atualizado."

      assert %{slug: "renomeado", max_running_tasks: 3, runner_log_retention_days: 0} =
               Workspaces.get_workspace!(workspace.id)
    end
  end

  describe "show" do
    setup do: %{workspace: workspace_fixture(%{name: "Acme"})}

    test "adds an existing user", %{conn: conn, workspace: workspace} do
      user = user_fixture(%{name: "Bruno"})
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}")

      html = view |> form("#add-existing-form", %{user_id: user.id}) |> render_submit()

      assert html =~ "Bruno agora faz parte de Acme."
      assert has_element?(view, "#member-#{user.id}")
    end

    test "asks for a user when none is chosen", %{conn: conn, workspace: workspace} do
      user_fixture()
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}")

      assert view |> form("#add-existing-form", %{user_id: ""}) |> render_submit() =~
               "Escolha um usuário."
    end

    test "creates a new user straight into the workspace", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}")

      assert view
             |> form("#new-member-form", user: %{name: "Caio", email: "x", password: "curta"})
             |> render_change() =~ "deve ser um e-mail válido"

      html =
        view
        |> form("#new-member-form",
          user: %{name: "Caio", email: "caio@acme.dev", password: valid_password()}
        )
        |> render_submit()

      assert html =~ "Caio criado e adicionado ao workspace."
      assert [%{email: "caio@acme.dev"}] = Workspaces.list_members(workspace)
    end

    test "keeps the form errors when creation fails", %{conn: conn, workspace: workspace} do
      existing = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}")

      assert view
             |> form("#new-member-form",
               user: %{name: "Dup", email: existing.email, password: valid_password()}
             )
             |> render_submit() =~ "já está em uso"
    end

    test "changes a member's role", %{conn: conn, workspace: workspace} do
      first = member_fixture(workspace, %{name: "Eva"})
      second = member_fixture(workspace, %{name: "Fabio"})
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}")

      assert has_element?(
               view,
               "[data-testid='member-role-#{first.email}'] option[selected][value=admin]"
             )

      assert has_element?(
               view,
               "[data-testid='member-role-#{second.email}'] option[selected][value=member]"
             )

      view
      |> form("#member-role-form-#{second.id}", role: %{role: "admin"})
      |> render_change()

      assert PipeMaestro.Workspaces.role(workspace, second) == :admin
    end

    test "removes a member", %{conn: conn, workspace: workspace} do
      user = member_fixture(workspace, %{name: "Dora"})
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}")

      assert view |> element("#member-#{user.id} button", "Remover") |> render_click() =~
               "Dora saiu de Acme."

      refute has_element?(view, "#member-#{user.id}")
    end

    test "a member cannot be added twice", %{conn: conn, workspace: workspace} do
      user = user_fixture(%{name: "Eva"})
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}")
      {:ok, _} = Workspaces.add_member(workspace, user)

      assert view |> form("#add-existing-form", %{user_id: user.id}) |> render_submit() =~
               "Eva já faz parte deste workspace."
    end
  end

  describe "runners" do
    test "lists the workspace's runners with their status", %{conn: conn} do
      workspace = workspace_fixture(%{name: "Acme"})

      {_runner, _token} =
        runner_fixture(workspace, member_fixture(workspace), %{name: "build-01"})

      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}")

      assert has_element?(view, "[data-testid=workspace-runner-build-01]")
      assert has_element?(view, "[data-testid=workspace-runner-status-build-01]", "Offline")

      PipeMaestroWeb.RunnerStatus.notify_changed(workspace.id)
      assert has_element?(view, "[data-testid=workspace-runners-online]", "0 online")
    end

    test "says when there are none", %{conn: conn} do
      workspace = workspace_fixture()
      {:ok, view, _html} = live(conn, ~p"/backoffice/workspaces/#{workspace}")
      assert has_element?(view, "[data-testid=workspace-no-runners]")
    end
  end
end
