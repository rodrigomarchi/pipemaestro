defmodule PipeMaestroWeb.Backoffice.OperatorSessionController do
  @moduledoc "Signs operators in and out of the backoffice; the form is `Backoffice.LoginLive`."
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Backoffice
  alias PipeMaestroWeb.OperatorAuth

  @doc "Checks the credentials posted by the backoffice sign-in form."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"operator" => %{"email" => email, "password" => password}}) do
    if operator = Backoffice.get_operator_by_email_and_password(email, password) do
      OperatorAuth.log_in_operator(conn, operator)
    else
      conn
      |> put_flash(:error, "E-mail ou senha inválidos.")
      |> redirect(to: ~p"/backoffice/login?#{[email: String.slice(email, 0, 160)]}")
    end
  end

  @doc "Signs the current operator out."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Você saiu do backoffice.")
    |> OperatorAuth.log_out_operator()
  end
end
