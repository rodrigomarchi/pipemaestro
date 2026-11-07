defmodule PipeMaestroWeb.UserAuth do
  @moduledoc """
  Sessions of workspace users: signing in and out, loading the current scope
  in plugs and LiveView mounts, and guarding routes that need a user or a
  workspace the user belongs to.
  """
  use PipeMaestroWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Phoenix.LiveView
  alias PipeMaestro.Accounts
  alias PipeMaestro.Accounts.{Scope, User}
  alias PipeMaestro.{Tasks, Workspaces}
  alias PipeMaestroWeb.NotificationHooks

  @remember_me_cookie "_pipe_maestro_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: Accounts.session_validity_in_days() * 24 * 60 * 60,
    same_site: "Lax"
  ]

  @doc """
  Signs `user` in: a fresh session (so a planted session id is useless), the
  token stored in it and, when asked, in a long-lived cookie.
  """
  @spec log_in_user(Plug.Conn.t(), User.t(), map()) :: Plug.Conn.t()
  def log_in_user(conn, %User{} = user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user)
    return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: return_to || ~p"/workspaces")
  end

  @doc "Signs the current user out and ends this session's token."
  @spec log_out_user(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out_user(conn) do
    if token = get_session(conn, :user_token), do: Accounts.delete_user_session_token(token)

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/login")
  end

  @doc """
  Sends every open LiveView of `user` back to the sign-in page. Their sessions
  were already ended in the database; this makes open tabs notice at once
  instead of on the next page load.
  """
  @spec disconnect_user(User.t()) :: :ok
  def disconnect_user(%User{} = user) do
    Phoenix.PubSub.broadcast(PipeMaestro.PubSub, sessions_topic(user), :session_revoked)
  end

  @doc "Plug that assigns `:current_scope` from the session or the remember-me cookie."
  @spec fetch_current_scope_for_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_scope_for_user(conn, _opts) do
    {token, conn} = ensure_user_token(conn)
    user = token && Accounts.get_user_by_session_token(token)
    assign(conn, :current_scope, Scope.for_user(user))
  end

  @doc "Plug that sends anonymous visitors to the sign-in page."
  @spec require_authenticated_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated_user(conn, _opts) do
    if signed_in?(conn.assigns.current_scope) do
      conn
    else
      conn
      |> put_flash(:error, "Entre para acessar esta página.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc "Plug that sends signed-in users away from the sign-in page."
  @spec redirect_if_user_is_authenticated(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def redirect_if_user_is_authenticated(conn, _opts) do
    if signed_in?(conn.assigns.current_scope) do
      conn |> redirect(to: ~p"/workspaces") |> halt()
    else
      conn
    end
  end

  @doc """
  LiveView `on_mount` hooks:

    * `:mount_current_scope` - assigns `:current_scope` (possibly `nil`)
    * `:require_authenticated` - halts to the sign-in page without a user
    * `:redirect_if_authenticated` - halts to the workspaces when a user is signed in
    * `:require_workspace` - loads the workspace in the `workspace_slug` param
      into the scope, and the user's workspaces into `:workspaces`; halts when
      the user does not belong to it
  """
  @spec on_mount(atom(), map(), map(), LiveView.Socket.t()) ::
          {:cont, LiveView.Socket.t()} | {:halt, LiveView.Socket.t()}
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{user: %User{} = user} ->
        {:cont, watch_session(socket, user)}

      _anonymous ->
        {:halt,
         socket
         |> LiveView.put_flash(:error, "Entre para acessar esta página.")
         |> LiveView.redirect(to: ~p"/login")}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if signed_in?(socket.assigns.current_scope) do
      {:halt, LiveView.redirect(socket, to: ~p"/workspaces")}
    else
      {:cont, socket}
    end
  end

  def on_mount(:require_workspace, %{"workspace_slug" => slug}, _session, socket) do
    %Scope{user: user} = scope = socket.assigns.current_scope

    case Workspaces.get_workspace_for_user(user, slug) do
      nil ->
        {:halt,
         socket
         |> LiveView.put_flash(:error, "Você não tem acesso a esse workspace.")
         |> LiveView.redirect(to: ~p"/workspaces")}

      workspace ->
        scope = Scope.put_workspace(scope, workspace, Workspaces.role(workspace, user))

        {:cont,
         socket
         |> Phoenix.Component.assign(
           current_scope: scope,
           workspaces: Workspaces.list_workspaces_for_user(user)
         )
         |> follow_pending_decisions(workspace)
         |> NotificationHooks.follow(scope)}
    end
  end

  # Every workspace page shows how many decisions wait (the menu's badge) and
  # tells when a task pauses or ends (a toast, and a browser notification
  # through the "notify" event), kept up to date here so no page has to.
  defp follow_pending_decisions(socket, workspace) do
    if LiveView.connected?(socket) do
      Tasks.subscribe({:decisions, workspace.id})
      Tasks.subscribe({:events, workspace.id})
    end

    socket
    |> Phoenix.Component.assign(pending_decisions: Tasks.count_awaiting(workspace))
    |> LiveView.attach_hook(:pending_decisions, :handle_info, fn
      {:pending_decisions, count}, socket ->
        {:halt, Phoenix.Component.assign(socket, pending_decisions: count)}

      {:task_event, event}, socket ->
        {:halt, notify_task_event(socket, workspace, event)}

      _other, socket ->
        {:cont, socket}
    end)
  end

  defp notify_task_event(socket, workspace, event) do
    {kind, title} =
      case event.kind do
        :awaiting -> {:info, "#{event.title} aguarda decisão"}
        :succeeded -> {:info, "#{event.title} foi concluída"}
        :failed -> {:error, "#{event.title} falhou"}
        :canceled -> {:info, "#{event.title} foi cancelada"}
      end

    socket
    |> LiveView.put_flash(kind, title)
    |> LiveView.push_event("notify", %{
      title: title,
      body: event.reason || "",
      url: ~p"/w/#{workspace.slug}/tasks/#{event.id}"
    })
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      user = session["user_token"] && Accounts.get_user_by_session_token(session["user_token"])
      Scope.for_user(user)
    end)
  end

  # A revoked session (password reset, user disabled) leaves this LiveView.
  defp watch_session(socket, user) do
    if LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(PipeMaestro.PubSub, sessions_topic(user))

      LiveView.attach_hook(socket, :session_revoked, :handle_info, fn
        :session_revoked, socket ->
          {:halt,
           socket
           |> LiveView.put_flash(:error, "Sua sessão foi encerrada.")
           |> LiveView.redirect(to: ~p"/login")}

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  defp signed_in?(%Scope{user: %User{}}), do: true
  defp signed_in?(_scope), do: false

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      case conn.cookies[@remember_me_cookie] do
        nil -> {nil, conn}
        token -> {token, put_session(conn, :user_token, token)}
      end
    end
  end

  # A fresh session id on every sign-in and sign-out defeats session fixation.
  # The backoffice session shares the cookie and survives it.
  defp renew_session(conn) do
    operator_token = get_session(conn, :operator_token)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> then(&if(operator_token, do: put_session(&1, :operator_token, operator_token), else: &1))
  end

  defp put_token_in_session(conn, token), do: put_session(conn, :user_token, token)

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params), do: conn

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp sessions_topic(%User{id: id}), do: "user_sessions:#{id}"
end
