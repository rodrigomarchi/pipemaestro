defmodule PipeMaestroWeb.Backoffice.OperatorLiveTest do
  use PipeMaestroWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Backoffice

  setup :register_and_log_in_operator

  test "lists operators and marks the current one", %{conn: conn, operator: operator} do
    {:ok, view, _html} = live(conn, ~p"/backoffice/operators")
    assert view |> element("#operator-#{operator.id}") |> render() =~ "(você)"
  end

  test "creates an operator", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/backoffice/operators/new")

    assert view
           |> form("#operator-form", operator: %{name: "", email: "x", password: ""})
           |> render_change() =~ "deve ser um e-mail válido"

    assert view
           |> form("#operator-form", operator: %{name: "", email: "x", password: ""})
           |> render_submit() =~ "deve ser um e-mail válido"

    html =
      view
      |> form("#operator-form",
        operator: %{name: "Paula", email: "paula@ops.dev", password: valid_password()}
      )
      |> render_submit()

    assert_patch(view, ~p"/backoffice/operators")
    assert html =~ "Operador Paula criado."
  end

  test "disables and re-enables another operator", %{conn: conn} do
    other = operator_fixture(%{name: "Rui"})
    token = Backoffice.generate_operator_session_token(other)
    {:ok, view, _html} = live(conn, ~p"/backoffice/operators")

    assert view |> element("#operator-#{other.id} button", "Desativar") |> render_click() =~
             "Rui desativado."

    refute Backoffice.get_operator_by_session_token(token)

    assert view |> element("#operator-#{other.id} button", "Reativar") |> render_click() =~
             "Rui reativado."
  end

  test "an operator cannot disable themselves", %{conn: conn, operator: operator} do
    {:ok, view, _html} = live(conn, ~p"/backoffice/operators")

    refute has_element?(view, "#operator-#{operator.id} button", "Desativar")

    assert render_click(view, "disable", %{"id" => operator.id}) =~
             "não pode desativar a si mesmo"
  end

  test "a disabled operator's open backoffice is closed", %{conn: conn, operator: operator} do
    {:ok, view, _html} = live(conn, ~p"/backoffice/operators")

    PipeMaestroWeb.OperatorAuth.disconnect_operator(operator)

    assert_redirect(view, ~p"/backoffice/login")
  end
end
