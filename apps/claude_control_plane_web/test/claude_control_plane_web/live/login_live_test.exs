defmodule ClaudeControlPlaneWeb.LoginLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the form, prefilled with a rejected e-mail", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login?email=ana@acme.dev")

    assert has_element?(view, ~s(#login-form input[type=email][value="ana@acme.dev"]))
    assert has_element?(view, "#login-form input[type=password]")
  end

  test "submitting posts the credentials to the session controller", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(conn, ~p"/login")

    form = form(view, "#login-form", user: %{email: user.email, password: valid_password()})
    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == ~p"/workspaces"
  end

  test "a signed-in user is sent to their workspaces", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:redirect, %{to: "/workspaces"}}} = live(conn, ~p"/login")
  end
end
