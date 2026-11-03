defmodule ClaudeControlPlaneWeb.Backoffice.UserLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.{Accounts, Workspaces}

  setup :register_and_log_in_operator

  describe "index" do
    test "lists users with their workspaces", %{conn: conn} do
      user = member_fixture(workspace_fixture(%{name: "Acme"}), %{name: "Ana"})
      {:ok, view, _html} = live(conn, ~p"/backoffice/users")

      assert view |> element("#user-#{user.id}") |> render() =~ "Acme"
    end

    test "creates a user and opens it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/backoffice/users/new")

      assert view
             |> form("#user-form", user: %{name: "", email: "", password: ""})
             |> render_change() =~ "não pode ficar em branco"

      assert view
             |> form("#user-form", user: %{name: "B", email: "bad", password: valid_password()})
             |> render_submit() =~ "deve ser um e-mail válido"

      {:ok, _show, html} =
        view
        |> form("#user-form",
          user: %{name: "Bruno", email: "bruno@acme.dev", password: valid_password()}
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Bruno criado."
    end

    test "shows the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backoffice/users")
      assert html =~ "Nenhum usuário ainda"
    end
  end

  describe "show" do
    setup do: %{user: user_fixture(%{name: "Ana"})}

    test "adds the user to a workspace and removes them", %{conn: conn, user: user} do
      workspace = workspace_fixture(%{name: "Acme"})
      {:ok, view, html} = live(conn, ~p"/backoffice/users/#{user}")
      assert html =~ "Ainda não faz parte de nenhum workspace"

      assert view |> form("#add-workspace-form", %{workspace_id: workspace.id}) |> render_submit() =~
               "Ana agora faz parte de Acme."

      assert view |> element("#user-workspace-#{workspace.id} button") |> render_click() =~
               "Ana saiu de Acme."

      assert Workspaces.list_workspaces_for_user(user) == []
    end

    test "asks for a workspace when none is chosen", %{conn: conn, user: user} do
      workspace_fixture()
      {:ok, view, _html} = live(conn, ~p"/backoffice/users/#{user}")

      assert view |> form("#add-workspace-form", %{workspace_id: ""}) |> render_submit() =~
               "Escolha um workspace."
    end

    test "reports a membership that already exists", %{conn: conn, user: user} do
      workspace = workspace_fixture(%{name: "Acme"})
      {:ok, view, _html} = live(conn, ~p"/backoffice/users/#{user}")
      {:ok, _} = Workspaces.add_member(workspace, user)

      assert view |> form("#add-workspace-form", %{workspace_id: workspace.id}) |> render_submit() =~
               "Ana já faz parte de Acme."
    end

    test "resets the password and ends the user's sessions", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      {:ok, view, _html} = live(conn, ~p"/backoffice/users/#{user}")

      view |> element("button", "Redefinir senha") |> render_click()

      assert view |> form("#password-form", user: %{password: "curta"}) |> render_change() =~
               "deve ter entre"

      assert view |> form("#password-form", user: %{password: "curta"}) |> render_submit() =~
               "deve ter entre"

      assert view
             |> form("#password-form", user: %{password: "nova senha bem longa"})
             |> render_submit() =~ "Senha de Ana redefinida."

      refute Accounts.get_user_by_session_token(token)
      assert Accounts.get_user_by_email_and_password(user.email, "nova senha bem longa")
    end

    test "the password dialog can be cancelled", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/backoffice/users/#{user}")

      view |> element("button", "Redefinir senha") |> render_click()
      assert has_element?(view, "#password-form")

      view |> element("#password-form button", "Cancelar") |> render_click()
      refute has_element?(view, "#password-form")
    end

    test "disables and re-enables the user", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/backoffice/users/#{user}")

      assert view |> element("button", "Desativar usuário") |> render_click() =~
               "Ana desativado."

      refute Accounts.get_user_by_email_and_password(user.email, valid_password())

      assert view |> element("button", "Reativar usuário") |> render_click() =~ "Ana reativado."
      assert Accounts.get_user_by_email_and_password(user.email, valid_password())
    end
  end
end
