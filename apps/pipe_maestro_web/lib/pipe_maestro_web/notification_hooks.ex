defmodule PipeMaestroWeb.NotificationHooks do
  @moduledoc """
  Keeps the notification center (`PipeMaestroWeb.NotificationCenter`) of
  every workspace page up to date, so no page has to: assigns
  `@notification_center` (`%{unread: count, active: executions}`), which each
  page hands to `PipeMaestroWeb.Layouts.app/1`, and follows the person's
  notifications and what runs in the workspace (`PipeMaestro.Notifications`).

  Only the center's own messages stop here, and a new notification also goes
  on to the inbox page (`PipeMaestroWeb.NotificationLive`); every other
  message goes on to the page.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias PipeMaestro.Accounts.Scope
  alias PipeMaestro.Notifications
  alias PipeMaestroWeb.NotificationCenter
  alias PipeMaestroWeb.NotificationLive

  # Changes closer than this make one reload of what runs.
  @debounce_ms 300

  # Pages that list the inbox themselves and so take a new notification too.
  @lists_inbox [NotificationLive]

  @doc "Assigns the center and, once connected, follows its messages."
  @spec follow(LiveView.Socket.t(), Scope.t()) :: LiveView.Socket.t()
  def follow(socket, %Scope{} = scope) do
    if LiveView.connected?(socket), do: Notifications.subscribe(scope)

    socket
    |> Component.assign(
      notification_center: %{
        unread: Notifications.count_unread(scope),
        active: Notifications.active_executions(scope.workspace)
      },
      notification_refresh: false
    )
    |> LiveView.attach_hook(:notifications, :handle_info, &handle_info(&1, &2, scope))
  end

  defp handle_info({:unread_count, count}, socket, _scope),
    do: {:halt, put_center(socket, unread: count)}

  # The page that lists the inbox also gets the notification, to put it at the top.
  defp handle_info({:notification, notification}, socket, _scope) do
    LiveView.send_update(NotificationCenter, id: "notification-center", prepend: notification)

    if socket.view in @lists_inbox,
      do: {:cont, socket},
      else: {:halt, socket}
  end

  defp handle_info({:executions_changed, _workspace_id}, socket, _scope) do
    if socket.assigns.notification_refresh do
      {:halt, socket}
    else
      Process.send_after(self(), :refresh_active_executions, @debounce_ms)
      {:halt, Component.assign(socket, notification_refresh: true)}
    end
  end

  defp handle_info(:refresh_active_executions, socket, scope) do
    {:halt,
     socket
     |> Component.assign(notification_refresh: false)
     |> put_center(active: Notifications.active_executions(scope.workspace))}
  end

  defp handle_info(_message, socket, _scope), do: {:cont, socket}

  defp put_center(socket, changes),
    do:
      Component.assign(
        socket,
        :notification_center,
        Map.merge(socket.assigns.notification_center, Map.new(changes))
      )
end
