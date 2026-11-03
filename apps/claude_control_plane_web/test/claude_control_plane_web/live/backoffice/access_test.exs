defmodule ClaudeControlPlaneWeb.Backoffice.AccessTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "anonymous visitors are sent to the backoffice sign-in", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/backoffice/workspaces")) == ~p"/backoffice/login"
    assert {:error, {:redirect, %{to: "/backoffice/login"}}} = live(conn, ~p"/backoffice/users")
  end

  test "a workspace user's session does not open the backoffice", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    assert redirected_to(get(conn, ~p"/backoffice/workspaces")) == ~p"/backoffice/login"
  end

  test "an operator's session does not open a workspace", %{conn: conn} do
    workspace = workspace_fixture()
    conn = log_in_operator(conn, operator_fixture())

    assert redirected_to(get(conn, ~p"/w/#{workspace.slug}")) == ~p"/login"
  end

  test "the backoffice sign-in renders and posts to the session controller", %{conn: conn} do
    operator = operator_fixture()
    {:ok, view, html} = live(conn, ~p"/backoffice/login?email=#{operator.email}")
    assert html =~ "Acesso de operadores"

    form =
      form(view, "#operator-login-form",
        operator: %{email: operator.email, password: valid_password()}
      )

    render_submit(form)
    assert redirected_to(follow_trigger_action(form, conn)) == ~p"/backoffice/workspaces"
  end

  test "a signed-in operator skips the sign-in", %{conn: conn} do
    conn = log_in_operator(conn, operator_fixture())

    assert {:error, {:redirect, %{to: "/backoffice/workspaces"}}} =
             live(conn, ~p"/backoffice/login")

    assert redirected_to(get(conn, ~p"/backoffice/login")) == ~p"/backoffice/workspaces"
  end

  test "the backoffice root lists workspaces", %{conn: conn} do
    conn = log_in_operator(conn, operator_fixture())
    {:ok, _view, html} = live(conn, ~p"/backoffice")
    assert html =~ "Nenhum workspace ainda"
  end
end
