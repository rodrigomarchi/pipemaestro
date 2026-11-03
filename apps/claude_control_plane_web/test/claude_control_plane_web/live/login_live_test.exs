defmodule ClaudeControlPlaneWeb.LoginLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the sign-in form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")

    assert has_element?(view, "#login-form input[type=email]")
    assert has_element?(view, "#login-form input[type=password]")
    assert render(view) =~ "Continuar com GitHub"
  end

  test "submitting the form goes to the board", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")

    {:ok, _board, html} =
      view
      |> form("#login-form", session: %{email: "ana@acme.dev", password: "secret"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/app")

    assert html =~ "Pipeline · bug fix"
  end

  test "signing in with GitHub goes to the board", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")

    assert {:error, {:live_redirect, %{to: "/app"}}} =
             view |> element("button", "Continuar com GitHub") |> render_click()
  end
end
