defmodule PipeMaestroWeb.UserSessionController do
  @moduledoc "Signs workspace users in and out; the form itself is `LoginLive`."
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Accounts
  alias PipeMaestroWeb.UserAuth

  @doc "Checks the credentials posted by the sign-in form."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"user" => %{"email" => email, "password" => password} = params}) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, "Que bom ter você de volta, #{first_name(user.name)}!")
      |> UserAuth.log_in_user(user, params)
    else
      conn
      |> put_flash(:error, "E-mail ou senha inválidos.")
      |> redirect(to: ~p"/login?#{[email: String.slice(email, 0, 160)]}")
    end
  end

  @doc "Signs the current user out."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Você saiu da sua conta.")
    |> UserAuth.log_out_user()
  end

  defp first_name(name), do: name |> String.split(" ", trim: true) |> List.first(name)
end
