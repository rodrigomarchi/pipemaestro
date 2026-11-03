defmodule ClaudeControlPlaneWeb.UserSessionControllerTest do
  use ClaudeControlPlaneWeb.ConnCase, async: true

  alias ClaudeControlPlane.Accounts

  setup do: %{user: user_fixture()}

  describe "POST /login" do
    test "signs the user in and goes to the workspaces", %{conn: conn, user: user} do
      conn = post(conn, ~p"/login", user: %{email: user.email, password: valid_password()})

      assert redirected_to(conn) == ~p"/workspaces"
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token)).id == user.id
      refute conn.resp_cookies["_claude_control_plane_user_remember_me"]
    end

    test "writes the remember-me cookie when asked", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/login",
          user: %{email: user.email, password: valid_password(), remember_me: "true"}
        )

      assert %{max_age: max_age} = conn.resp_cookies["_claude_control_plane_user_remember_me"]
      assert max_age == Accounts.session_validity_in_days() * 86_400
    end

    test "goes back to the page that asked for sign-in", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/w/acme")
        |> post(~p"/login", user: %{email: user.email, password: valid_password()})

      assert redirected_to(conn) == "/w/acme"
    end

    test "rejects wrong credentials and keeps the e-mail", %{conn: conn, user: user} do
      conn = post(conn, ~p"/login", user: %{email: user.email, password: "senha errada demais"})

      assert redirected_to(conn) == ~p"/login?#{[email: user.email]}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "E-mail ou senha inválidos."
      refute get_session(conn, :user_token)
    end

    test "rejects a disabled user with the same message", %{conn: conn, user: user} do
      {:ok, _} = Accounts.disable_user(user)
      conn = post(conn, ~p"/login", user: %{email: user.email, password: valid_password()})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "E-mail ou senha inválidos."
    end

    test "keeps a backoffice session that is already open", %{conn: conn, user: user} do
      operator = operator_fixture()

      conn =
        conn
        |> log_in_operator(operator)
        |> post(~p"/login", user: %{email: user.email, password: valid_password()})

      assert get_session(conn, :operator_token)
      assert get_session(conn, :user_token)
    end
  end

  describe "DELETE /logout" do
    test "ends the session", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/logout")
      token = get_session(conn, :user_token)

      assert redirected_to(conn) == ~p"/login"
      refute token
    end

    test "works without a session", %{conn: conn} do
      assert conn |> delete(~p"/logout") |> redirected_to() == ~p"/login"
    end
  end

  test "the remember-me cookie restores a session", %{conn: conn, user: user} do
    signed_in =
      post(conn, ~p"/login",
        user: %{email: user.email, password: valid_password(), remember_me: "true"}
      )

    cookie = signed_in.resp_cookies["_claude_control_plane_user_remember_me"]

    conn =
      build_conn()
      |> put_req_cookie("_claude_control_plane_user_remember_me", cookie.value)
      |> get(~p"/workspaces")

    assert conn.assigns.current_scope.user.id == user.id
  end
end
