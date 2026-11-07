defmodule PipeMaestroWeb.NotificationLive do
  @moduledoc """
  Every notification of the person in the workspace
  (`PipeMaestro.Notifications`), newest first, in pages: all of them or only
  the unread (`?filtro=nao-lidas`, so the filter survives a reload). A click
  opens what the notification is about and marks it read; "Marcar todas como
  lidas" clears the inbox. Reached from the notification center's "Ver
  todas".
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.Notifications
  alias PipeMaestroWeb.NotificationComponents

  @page 20

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Notificações")}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(unread_only: params["filtro"] == "nao-lidas")
     |> load()}
  end

  # A notification that arrives while the page is open goes to its top (the hook
  # lets this one through: see `PipeMaestroWeb.NotificationHooks`).
  @impl true
  def handle_info({:notification, notification}, socket),
    do: {:noreply, update(socket, :notifications, &[notification | &1])}

  @impl true
  def handle_event("filter", %{"filter" => "unread"}, socket),
    do: {:noreply, push_patch(socket, to: filter_path(socket, filtro: "nao-lidas"))}

  def handle_event("filter", _params, socket),
    do: {:noreply, push_patch(socket, to: filter_path(socket, []))}

  def handle_event("load_more", _params, socket) do
    last = List.last(socket.assigns.notifications)
    {page, more} = fetch(socket, {last.inserted_at, last.id})
    {:noreply, assign(socket, notifications: socket.assigns.notifications ++ page, more: more)}
  end

  def handle_event("open", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Notifications.mark_read(scope, id) do
      {:ok, notification} ->
        {:noreply,
         push_navigate(socket,
           to: NotificationComponents.path(scope.workspace.slug, notification)
         )}

      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("mark_all_read", _params, socket) do
    Notifications.mark_all_read(socket.assigns.current_scope)
    {:noreply, load(socket)}
  end

  defp filter_path(socket, query),
    do: ~p"/w/#{socket.assigns.current_scope.workspace.slug}/notifications?#{query}"

  defp load(socket) do
    {page, more} = fetch(socket, nil)
    assign(socket, notifications: page, more: more)
  end

  # One page more than shown says whether there is another.
  defp fetch(socket, before) do
    page =
      Notifications.list_for(socket.assigns.current_scope,
        limit: @page + 1,
        before: before,
        unread: socket.assigns.unread_only
      )

    {Enum.take(page, @page), length(page) > @page}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:notifications}
      title="Notificações"
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
    >
      <:actions>
        <.tabs variant="segmented">
          <.tab
            link_type="button"
            variant="segmented"
            is_active={not @unread_only}
            phx-click="filter"
            phx-value-filter="all"
            data-testid="notifications-filter-all"
          >
            Todas
          </.tab>
          <.tab
            link_type="button"
            variant="segmented"
            is_active={@unread_only}
            phx-click="filter"
            phx-value-filter="unread"
            data-testid="notifications-filter-unread"
          >
            Não lidas
          </.tab>
        </.tabs>
        <.button
          :if={@notification_center.unread > 0}
          size="sm"
          color="white"
          variant="outline"
          icon="hero-check"
          phx-click="mark_all_read"
          aria-label="Marcar todas como lidas"
          data-testid="notifications-mark-all-read"
        >
          <span class="hidden sm:inline">Marcar todas como lidas</span>
        </.button>
      </:actions>

      <div class="mx-auto max-w-3xl space-y-4" data-testid="notifications-page">
        <.card :if={@notifications == []}>
          <.card_content>
            <NotificationComponents.empty_inbox unread_only={@unread_only} />
          </.card_content>
        </.card>

        <.card :if={@notifications != []}>
          <.card_content>
            <ul role="list" class="space-y-1">
              <NotificationComponents.notification_item
                :for={notification <- @notifications}
                notification={notification}
              />
            </ul>
          </.card_content>
        </.card>

        <div :if={@more} class="flex justify-center">
          <.button
            color="white"
            variant="outline"
            phx-click="load_more"
            data-testid="notifications-load-more"
          >
            Carregar mais
          </.button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
