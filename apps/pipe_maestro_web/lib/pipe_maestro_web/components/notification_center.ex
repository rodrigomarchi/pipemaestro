defmodule PipeMaestroWeb.NotificationCenter do
  @moduledoc """
  The notification center of the top bar (`PipeMaestroWeb.Layouts.app/1`):
  the bell, with the unread count and a dot while something runs, and the
  panel it opens over the page, with two tabs: what is under way now and the
  person's inbox.

  The counts and the executions come from the page (`center`, kept up to
  date by `PipeMaestroWeb.NotificationHooks`); whether the panel is open,
  its tab, the "mine / everyone" toggle, the inbox's filter and pages are
  this component's own, so opening and closing it never touches the page.
  A notification that arrives while the inbox is shown is put at its top
  (`send_update/3` with `prepend: notification`).
  """
  use PipeMaestroWeb, :live_component

  alias PetalComponents.SlideOver
  alias PipeMaestro.Notifications
  alias PipeMaestroWeb.NotificationComponents

  @page 20

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open: false,
       tab: :active,
       mine: false,
       unread_only: false,
       inbox: [],
       more: false
     )}
  end

  @impl true
  def update(%{prepend: notification}, socket) do
    if socket.assigns.open and socket.assigns.tab == :inbox,
      do: {:ok, update(socket, :inbox, &[notification | &1])},
      else: {:ok, socket}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("open", _params, socket),
    do: {:noreply, assign(socket, open: true, tab: :active)}

  def handle_event("close_slide_over", _params, socket),
    do: {:noreply, assign(socket, open: false, inbox: [])}

  def handle_event("tab", %{"tab" => "inbox"}, socket),
    do: {:noreply, socket |> assign(tab: :inbox) |> load_inbox()}

  def handle_event("tab", _params, socket), do: {:noreply, assign(socket, tab: :active)}

  def handle_event("toggle_mine", _params, socket),
    do: {:noreply, assign(socket, mine: not socket.assigns.mine)}

  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, socket |> assign(unread_only: filter == "unread") |> load_inbox()}

  def handle_event("load_more", _params, socket) do
    last = List.last(socket.assigns.inbox)
    {page, more} = fetch(socket, last && {last.inserted_at, last.id})
    {:noreply, assign(socket, inbox: socket.assigns.inbox ++ page, more: more)}
  end

  def handle_event("open_notification", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Notifications.mark_read(scope, id) do
      {:ok, notification} ->
        {:noreply,
         push_navigate(socket,
           to: NotificationComponents.path(scope.workspace.slug, notification)
         )}

      {:error, :not_found} ->
        {:noreply, load_inbox(socket)}
    end
  end

  def handle_event("mark_all_read", _params, socket) do
    Notifications.mark_all_read(socket.assigns.current_scope)
    {:noreply, load_inbox(socket)}
  end

  defp load_inbox(socket) do
    {page, more} = fetch(socket, nil)
    assign(socket, inbox: page, more: more)
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
    active = visible(assigns.center.active, assigns.mine, assigns.current_scope.user.id)

    assigns =
      assign(assigns,
        slug: assigns.current_scope.workspace.slug,
        unread: assigns.center.unread,
        running?: Enum.any?(assigns.center.active, &(&1.status in [:running, :queued])),
        groups: Notifications.group(active),
        empty_active?: active == []
      )

    ~H"""
    <div id={@id} class="relative">
      <.button
        color="white"
        variant="outline"
        size="sm"
        class="relative !px-2"
        phx-click={JS.push_focus() |> JS.push("open", target: @myself)}
        aria-label={bell_label(@unread, @running?)}
        aria-haspopup="dialog"
        aria-expanded={to_string(@open)}
        data-testid="notifications-bell"
      >
        <.icon name="hero-bell" class="size-5" />
        <span
          :if={@unread > 0}
          aria-hidden="true"
          class="absolute -right-1.5 -top-1.5 min-w-5 rounded-full bg-danger-600 px-1 text-center text-[11px] font-semibold leading-5 text-white"
          data-testid="notifications-unread-count"
        >{if @unread > 9, do: "9+", else: @unread}</span>
        <span
          :if={@running?}
          aria-hidden="true"
          class="absolute -bottom-0.5 -right-0.5 flex size-2.5"
          data-testid="notifications-activity-indicator"
        >
          <span class="absolute inline-flex size-full animate-ping rounded-full bg-success-400 opacity-75 motion-reduce:hidden"></span>
          <span class="relative inline-flex size-2.5 rounded-full bg-success-500"></span>
        </span>
      </.button>
      <SlideOver.slide_over
        :if={@open}
        id="notifications-panel"
        origin="right"
        max_width="md"
        title="Notificações"
        close_slide_over_target={"##{@id}"}
        on_close={JS.pop_focus()}
        class="max-sm:!max-w-full"
      >
        <div data-testid="notifications-panel">
          <.tabs variant="segmented" class="mb-4" data-testid="notifications-tabs">
            <.tab
              link_type="button"
              variant="segmented"
              is_active={@tab == :active}
              number={length(@center.active)}
              phx-click="tab"
              phx-value-tab="active"
              phx-target={@myself}
              data-testid="notifications-tab-active"
            >
              Em andamento
            </.tab>
            <.tab
              link_type="button"
              variant="segmented"
              is_active={@tab == :inbox}
              number={if @unread > 0, do: @unread}
              phx-click="tab"
              phx-value-tab="inbox"
              phx-target={@myself}
              data-testid="notifications-tab-inbox"
            >
              Notificações
            </.tab>
          </.tabs>

          <div :if={@tab == :active} class="space-y-4">
            <div class="flex justify-end">
              <.button
                size="xs"
                color="white"
                variant="outline"
                icon={if @mine, do: "hero-user", else: "hero-users"}
                phx-click="toggle_mine"
                phx-target={@myself}
                aria-pressed={to_string(@mine)}
                data-testid="notifications-mine-toggle"
              >
                {if @mine, do: "Minhas", else: "Todas"}
              </.button>
            </div>

            <NotificationComponents.empty_active :if={@empty_active?} slug={@slug} />

            <.execution_group
              :for={
                {key, testid, label} <- [
                  {:running, "running", "Rodando"},
                  {:awaiting_decision, "awaiting", "Aguardando decisão"},
                  {:queued, "queued", "Na fila"}
                ]
              }
              :if={@groups[key] != []}
              testid={testid}
              label={label}
              executions={@groups[key]}
              slug={@slug}
            />
          </div>

          <div :if={@tab == :inbox} class="space-y-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <.tabs variant="segmented">
                <.tab
                  link_type="button"
                  variant="segmented"
                  is_active={not @unread_only}
                  phx-click="filter"
                  phx-value-filter="all"
                  phx-target={@myself}
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
                  phx-target={@myself}
                  data-testid="notifications-filter-unread"
                >
                  Não lidas
                </.tab>
              </.tabs>
              <.button
                :if={@unread > 0}
                size="xs"
                color="white"
                variant="outline"
                icon="hero-check"
                phx-click="mark_all_read"
                phx-target={@myself}
                data-testid="notifications-mark-all-read"
              >
                Marcar todas como lidas
              </.button>
            </div>

            <NotificationComponents.empty_inbox :if={@inbox == []} unread_only={@unread_only} />

            <ul :if={@inbox != []} role="list" class="space-y-2">
              <NotificationComponents.notification_item
                :for={notification <- @inbox}
                notification={notification}
                event="open_notification"
                target={@myself}
              />
            </ul>

            <div :if={@more} class="flex justify-center">
              <.button
                size="sm"
                color="white"
                variant="outline"
                phx-click="load_more"
                phx-target={@myself}
                data-testid="notifications-load-more"
              >
                Carregar mais
              </.button>
            </div>
          </div>
        </div>

        <:footer>
          <div class="flex w-full items-center justify-between gap-2">
            <.link
              navigate={~p"/w/#{@slug}/notifications"}
              class="text-sm font-medium text-primary-600 hover:underline dark:text-primary-400"
              data-testid="notifications-see-all"
            >
              Ver todas as notificações
            </.link>
            <.button
              size="sm"
              color="white"
              variant="outline"
              phx-click={close_js(@id)}
              data-testid="notifications-close"
            >
              Fechar
            </.button>
          </div>
        </:footer>
      </SlideOver.slide_over>
    </div>
    """
  end

  attr :testid, :string, required: true
  attr :label, :string, required: true
  attr :executions, :list, required: true
  attr :slug, :string, required: true

  defp execution_group(assigns) do
    ~H"""
    <section data-testid={"notifications-group-#{@testid}"}>
      <h3 class="px-3 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
        {@label} ({length(@executions)})
      </h3>
      <ul role="list" class="mt-1 space-y-2">
        <NotificationComponents.execution_item
          :for={execution <- @executions}
          execution={execution}
          slug={@slug}
        />
      </ul>
    </section>
    """
  end

  # The panel's own way out (as its close button), and the focus back to the bell.
  defp close_js(id) do
    %JS{ops: hide} = SlideOver.hide_slide_over("right", "notifications-panel", "#" <> id)
    %JS{ops: JS.pop_focus().ops ++ hide}
  end

  defp visible(executions, false, _user_id), do: executions

  defp visible(executions, true, user_id),
    do: Enum.filter(executions, &(&1.creator_id == user_id))

  defp bell_label(unread, running?) do
    unread_text =
      case unread do
        0 -> "nenhuma não lida"
        1 -> "1 não lida"
        n -> "#{n} não lidas"
      end

    if running?,
      do: "Notificações, #{unread_text}, execuções em andamento",
      else: "Notificações, #{unread_text}"
  end
end
