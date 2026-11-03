defmodule ClaudeControlPlaneWeb.OperatorAuth do
  @moduledoc """
  Backoffice sessions of platform operators. Kept apart from `UserAuth`: its
  own session key and routes, a shorter validity and no remember-me, so a
  workspace user's session never opens the backoffice.
  """
  use ClaudeControlPlaneWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias ClaudeControlPlane.Backoffice
  alias ClaudeControlPlane.Backoffice.Operator
  alias Phoenix.LiveView

  @doc "Signs `operator` in with a fresh session."
  @spec log_in_operator(Plug.Conn.t(), Operator.t()) :: Plug.Conn.t()
  def log_in_operator(conn, %Operator{} = operator) do
    token = Backoffice.generate_operator_session_token(operator)
    return_to = get_session(conn, :operator_return_to)

    conn
    |> renew_session()
    |> put_session(:operator_token, token)
    |> redirect(to: return_to || ~p"/backoffice/workspaces")
  end

  @doc "Signs the current operator out and ends this session's token."
  @spec log_out_operator(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out_operator(conn) do
    if token = get_session(conn, :operator_token),
      do: Backoffice.delete_operator_session_token(token)

    conn
    |> renew_session()
    |> redirect(to: ~p"/backoffice/login")
  end

  @doc "Sends every open backoffice LiveView of `operator` back to the sign-in page."
  @spec disconnect_operator(Operator.t()) :: :ok
  def disconnect_operator(%Operator{} = operator) do
    Phoenix.PubSub.broadcast(
      ClaudeControlPlane.PubSub,
      sessions_topic(operator),
      :session_revoked
    )
  end

  @doc "Plug that assigns `:current_operator` (or `nil`) from the session."
  @spec fetch_current_operator(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_operator(conn, _opts) do
    token = get_session(conn, :operator_token)
    assign(conn, :current_operator, token && Backoffice.get_operator_by_session_token(token))
  end

  @doc "Plug that sends visitors without an operator session to the backoffice sign-in."
  @spec require_authenticated_operator(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated_operator(conn, _opts) do
    if conn.assigns[:current_operator] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/backoffice/login")
      |> halt()
    end
  end

  @doc "Plug that sends signed-in operators away from the backoffice sign-in."
  @spec redirect_if_operator_is_authenticated(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def redirect_if_operator_is_authenticated(conn, _opts) do
    if conn.assigns[:current_operator] do
      conn |> redirect(to: ~p"/backoffice/workspaces") |> halt()
    else
      conn
    end
  end

  @doc """
  LiveView `on_mount` hooks:

    * `:require_authenticated` - assigns `:current_operator`; halts to the
      backoffice sign-in without one
    * `:redirect_if_authenticated` - halts to the backoffice when an operator
      is signed in
  """
  @spec on_mount(atom(), map(), map(), LiveView.Socket.t()) ::
          {:cont, LiveView.Socket.t()} | {:halt, LiveView.Socket.t()}
  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_operator(socket, session)

    case socket.assigns.current_operator do
      %Operator{} = operator ->
        {:cont, watch_session(socket, operator)}

      nil ->
        {:halt, LiveView.redirect(socket, to: ~p"/backoffice/login")}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_operator(socket, session)

    if socket.assigns.current_operator do
      {:halt, LiveView.redirect(socket, to: ~p"/backoffice/workspaces")}
    else
      {:cont, socket}
    end
  end

  defp mount_current_operator(socket, session) do
    Phoenix.Component.assign_new(socket, :current_operator, fn ->
      token = session["operator_token"]
      token && Backoffice.get_operator_by_session_token(token)
    end)
  end

  # A revoked session (operator disabled) leaves this LiveView.
  defp watch_session(socket, operator) do
    if LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(ClaudeControlPlane.PubSub, sessions_topic(operator))

      LiveView.attach_hook(socket, :session_revoked, :handle_info, fn
        :session_revoked, socket ->
          {:halt,
           socket
           |> LiveView.put_flash(:error, "Sua sessão foi encerrada.")
           |> LiveView.redirect(to: ~p"/backoffice/login")}

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  # A fresh session id on every sign-in and sign-out defeats session fixation.
  # The workspace-user session shares the cookie and survives it.
  defp renew_session(conn) do
    user_token = get_session(conn, :user_token)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> then(&if(user_token, do: put_session(&1, :user_token, user_token), else: &1))
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :operator_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp sessions_topic(%Operator{id: id}), do: "operator_sessions:#{id}"
end
