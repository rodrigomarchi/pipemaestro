defmodule PipeMaestroWeb.UserRegistrationControllerTest do
  use PipeMaestroWeb.ConnCase, async: true

  alias PipeMaestro.Accounts

  defp sign_up(conn, attrs) do
    post(conn, ~p"/signup",
      user: Enum.into(attrs, %{name: "Bia", email: unique_email(), password: valid_password()})
    )
  end

  test "creates the account, signs it in and goes on to the workspaces", %{conn: conn} do
    conn = sign_up(conn, email: "bia@acme.dev")

    assert redirected_to(conn) == ~p"/workspaces"
    user = Accounts.get_user_by_email("bia@acme.dev")
    assert Accounts.get_user_by_session_token(get_session(conn, :user_token)).id == user.id

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Conta criada! Agora dê um nome ao seu workspace."
  end

  test "a refused account goes back to the form, filled in", %{conn: conn} do
    user = user_fixture()
    conn = sign_up(conn, name: "Bia", email: user.email)

    assert redirected_to(conn) == ~p"/signup"
    assert get_session(conn, :signup) == %{"name" => "Bia", "email" => user.email}

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Não foi possível criar a conta: e-mail já está em uso."

    refute get_session(conn, :user_token)
  end

  test "an address that signed up five times in the hour must wait", %{conn: conn} do
    for _ <- 1..5, do: assert(redirected_to(sign_up(conn, %{})) == ~p"/workspaces")

    conn = sign_up(conn, email: "sexta@acme.dev")

    assert redirected_to(conn) == ~p"/signup"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Muitos cadastros deste endereço. Tente mais tarde."

    refute Accounts.get_user_by_email("sexta@acme.dev")
  end

  test "a signed-in user cannot sign up again", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> sign_up(%{})
    assert redirected_to(conn) == ~p"/workspaces"
  end
end
