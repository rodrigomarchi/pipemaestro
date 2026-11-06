defmodule PipeMaestroWeb.IntegrationOAuthController do
  @moduledoc """
  Where a git host sends a person back after they authorize a connection
  (`PipeMaestroWeb.IntegrationOAuth`): the code becomes the connection's
  tokens, if the `state` is valid, belongs to the signed-in person and they
  still administer the connection's workspace.
  """
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Accounts.Scope
  alias PipeMaestro.{Authorization, Integrations, Workspaces}
  alias PipeMaestro.Integrations.{Connection, Credentials}
  alias PipeMaestroWeb.{IntegrationComponents, IntegrationOAuth}

  @doc "Takes the host's answer."
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    user = conn.assigns.current_scope.user

    with {:ok, state} <- IntegrationOAuth.read_state(params["state"]),
         true <- state.user_id == user.id || :not_yours,
         %Connection{} = connection <- Integrations.get_connection(state.connection_id) || :gone,
         workspace = Workspaces.get_workspace!(connection.workspace_id),
         true <- admin?(workspace, user) || :not_admin do
      finish(conn, workspace, connection, state, params)
    else
      :not_admin ->
        conn |> put_status(403) |> text("Só admins do workspace conectam integrações.")

      _invalid ->
        conn
        |> put_flash(:error, "A autorização expirou ou não é desta sessão. Tente de novo.")
        |> redirect(to: ~p"/workspaces")
    end
  end

  @doc """
  Takes whoever installed the GitHub App back: the installation becomes the
  connection's once the person, signed in on GitHub (`code`), is shown to
  reach it.
  """
  @spec github_setup(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def github_setup(conn, params) do
    user = conn.assigns.current_scope.user

    with {:ok, state} <- IntegrationOAuth.read_state(params["state"]),
         true <- state.user_id == user.id || :not_yours,
         %Connection{} = connection <- Integrations.get_connection(state.connection_id) || :gone,
         workspace = Workspaces.get_workspace!(connection.workspace_id),
         true <- admin?(workspace, user) || :not_admin,
         %{"installation_id" => installation, "code" => code} <- params do
      page = ~p"/w/#{workspace.slug}/integrations/#{connection.id}"

      case Integrations.confirm_installation(connection, installation, code) do
        {:ok, _connection} ->
          conn |> put_flash(:info, "GitHub App instalado.") |> redirect(to: page)

        {:error, message} ->
          conn
          |> put_flash(:error, "A instalação não foi confirmada: #{message}")
          |> redirect(to: page)
      end
    else
      :not_admin ->
        conn |> put_status(403) |> text("Só admins do workspace conectam integrações.")

      _invalid ->
        conn
        |> put_flash(:error, "A instalação expirou ou não é desta sessão. Tente de novo.")
        |> redirect(to: ~p"/workspaces")
    end
  end

  defp finish(conn, workspace, connection, state, params) do
    page = ~p"/w/#{workspace.slug}/integrations/#{connection.id}"

    case params do
      %{"code" => code} ->
        case Credentials.exchange_code(
               connection,
               code,
               state.verifier,
               IntegrationComponents.oauth_redirect_uri()
             ) do
          {:ok, connection} ->
            connection = Integrations.check_connection(connection)

            conn
            |> put_flash(:info, "Conexão autorizada, como #{connection.bot_login}.")
            |> redirect(to: page)

          {:error, message} ->
            conn
            |> put_flash(:error, "O Forgejo recusou a autorização: #{message}")
            |> redirect(to: page)
        end

      _denied ->
        conn |> put_flash(:error, "A autorização foi negada no Forgejo.") |> redirect(to: page)
    end
  end

  defp admin?(workspace, user) do
    scope = %Scope{user: user, workspace: workspace, role: Workspaces.role(workspace, user)}
    Authorization.can?(scope, :manage_integrations)
  end
end
