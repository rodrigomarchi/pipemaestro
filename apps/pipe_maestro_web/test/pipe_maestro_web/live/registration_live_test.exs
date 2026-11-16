defmodule PipeMaestroWeb.RegistrationLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Accounts

  test "renders the sign-up form, posting to the registration controller", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/signup")

    assert html =~ "Plano Free"
    assert has_element?(view, ~s(#signup-form[action="/signup"]))
    assert has_element?(view, ~s([data-testid="signup-name"]))
    assert has_element?(view, ~s([data-testid="signup-email"]))
    assert has_element?(view, ~s([data-testid="signup-password"]))
    assert has_element?(view, ~s(a[href="/login"]), "Entrar")
  end

  test "points out a taken e-mail and a short password as they are typed", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(conn, ~p"/signup")

    html =
      view
      |> form("#signup-form", user: %{name: "Bia", email: user.email, password: "123"})
      |> render_change()

    assert html =~ "já está em uso"
    assert html =~ "deve ter entre 6 e 72 caracteres"
  end

  test "comes back filled in after the controller refused it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/signup?name=Bia&email=bia@acme.dev")

    assert has_element?(view, ~s(#signup-form input[type=email][value="bia@acme.dev"]))
    assert has_element?(view, ~s(#signup-form input[value="Bia"]))
  end

  test "a valid form is posted to the controller, which creates the account", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/signup")

    form =
      form(view, "#signup-form",
        user: %{name: "Bia", email: "bia@acme.dev", password: valid_password()}
      )

    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == ~p"/workspaces"
    assert Accounts.get_user_by_email("bia@acme.dev")
  end

  test "an invalid form stays on the page with its errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/signup")

    html =
      view
      |> form("#signup-form", user: %{name: "", email: "nope", password: valid_password()})
      |> render_submit()

    assert html =~ "deve ser um e-mail válido"
    refute has_element?(view, ~s(#signup-form[phx-trigger-action]))
  end

  test "a signed-in user is sent to their workspaces", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:redirect, %{to: "/workspaces"}}} = live(conn, ~p"/signup")
  end
end
