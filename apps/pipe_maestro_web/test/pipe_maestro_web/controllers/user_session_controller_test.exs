defmodule PipeMaestroWeb.UserSessionControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  alias PipeMaestro.Accounts

  setup do: %{user: user_fixture()}

  describe "POST /login, too many attempts" do
    @blocked "Muitas tentativas. Tente de novo em alguns minutos."

    defp attempt(conn, ip, email, password) do
      %{conn | remote_ip: ip} |> post(~p"/login", user: %{email: email, password: password})
    end

    test "an address that failed ten times is stopped, even with the right password",
         %{conn: conn, user: user} do
      ip = conn.remote_ip

      for n <- 1..10 do
        attempt(conn, ip, "outra#{n}@example.com", "senha errada demais")
      end

      conn = attempt(conn, ip, user.email, valid_password())

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @blocked
      refute get_session(conn, :user_token)
    end

    test "an e-mail tried ten times is stopped, from any address", %{conn: conn, user: user} do
      for n <- 1..10 do
        attempt(conn, {10, 200, 1, n}, user.email, "senha errada demais")
      end

      conn = attempt(conn, {10, 200, 2, 1}, user.email, valid_password())

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @blocked
      refute get_session(conn, :user_token)
    end

    test "behind the proxy, each client counts on its own", %{conn: conn, user: user} do
      proxied = fn client ->
        %{conn | remote_ip: {127, 0, 0, 1}}
        |> put_req_header("x-forwarded-for", client)
        |> post(~p"/login", user: %{email: unique_email(), password: "senha errada demais"})
      end

      for _ <- 1..10, do: proxied.("203.0.113.#{rem(System.unique_integer([:positive]), 250)}")
      blocked_client = "198.51.100.#{rem(System.unique_integer([:positive]), 250)}"
      for _ <- 1..10, do: proxied.(blocked_client)

      assert Phoenix.Flash.get(proxied.(blocked_client).assigns.flash, :error) == @blocked

      conn =
        %{conn | remote_ip: {127, 0, 0, 1}}
        |> put_req_header(
          "x-forwarded-for",
          "192.0.2.#{rem(System.unique_integer([:positive]), 250)}"
        )
        |> post(~p"/login", user: %{email: user.email, password: valid_password()})

      assert redirected_to(conn) == ~p"/workspaces"
    end

    test "below the limit, signing in works", %{conn: conn, user: user} do
      for _ <- 1..9, do: attempt(conn, conn.remote_ip, user.email, "senha errada demais")

      conn = attempt(conn, conn.remote_ip, user.email, valid_password())
      assert redirected_to(conn) == ~p"/workspaces"
      assert get_session(conn, :user_token)
    end
  end

  describe "POST /login" do
    test "signs the user in and goes to the workspaces", %{conn: conn, user: user} do
      conn = post(conn, ~p"/login", user: %{email: user.email, password: valid_password()})

      assert redirected_to(conn) == ~p"/workspaces"
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token)).id == user.id
      refute conn.resp_cookies["_pipe_maestro_user_remember_me"]
    end

    test "writes the remember-me cookie when asked", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/login",
          user: %{email: user.email, password: valid_password(), remember_me: "true"}
        )

      assert %{max_age: max_age} = conn.resp_cookies["_pipe_maestro_user_remember_me"]
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

    cookie = signed_in.resp_cookies["_pipe_maestro_user_remember_me"]

    conn =
      build_conn()
      |> put_req_cookie("_pipe_maestro_user_remember_me", cookie.value)
      |> get(~p"/workspaces")

    assert conn.assigns.current_scope.user.id == user.id
  end
end
