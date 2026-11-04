defmodule PipeMaestroWeb.Backoffice.OperatorSessionControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  alias PipeMaestro.Backoffice

  setup do: %{operator: operator_fixture()}

  test "signs the operator in", %{conn: conn, operator: operator} do
    conn =
      post(conn, ~p"/backoffice/login",
        operator: %{email: operator.email, password: valid_password()}
      )

    assert redirected_to(conn) == ~p"/backoffice/workspaces"
    assert Backoffice.get_operator_by_session_token(get_session(conn, :operator_token))
  end

  test "rejects wrong credentials", %{conn: conn, operator: operator} do
    conn =
      post(conn, ~p"/backoffice/login",
        operator: %{email: operator.email, password: "senha errada demais"}
      )

    assert redirected_to(conn) == ~p"/backoffice/login?#{[email: operator.email]}"
    refute get_session(conn, :operator_token)
  end

  test "a user's credentials do not open the backoffice", %{conn: conn} do
    user = user_fixture()

    conn =
      post(conn, ~p"/backoffice/login",
        operator: %{email: user.email, password: valid_password()}
      )

    refute get_session(conn, :operator_token)
  end

  test "signs out, keeping a workspace session", %{conn: conn, operator: operator} do
    conn =
      conn
      |> log_in_user(user_fixture())
      |> log_in_operator(operator)
      |> delete(~p"/backoffice/logout")

    assert redirected_to(conn) == ~p"/backoffice/login"
    refute get_session(conn, :operator_token)
    assert get_session(conn, :user_token)
  end
end
