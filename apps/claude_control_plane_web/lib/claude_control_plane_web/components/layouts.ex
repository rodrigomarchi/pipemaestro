defmodule ClaudeControlPlaneWeb.Layouts do
  @moduledoc """
  The page chrome: the root HTML skeleton, the public layout (landing and sign
  in) and the signed-in app shell with its sidebar.
  """
  use ClaudeControlPlaneWeb, :html

  embed_templates "layouts/*"

  @doc """
  The public layout: top navigation, page content and footer.

  ## Examples

      <Layouts.public flash={@flash}>
        <h1>Content</h1>
      </Layouts.public>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :nav, :boolean, default: true, doc: "renders the top navigation and footer"

  slot :inner_block, required: true

  @spec public(map()) :: Phoenix.LiveView.Rendered.t()
  def public(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col bg-white dark:bg-gray-950">
      <header
        :if={@nav}
        class="sticky top-0 z-30 border-b border-gray-200/70 bg-white/80 backdrop-blur dark:border-gray-800/70 dark:bg-gray-950/80"
      >
        <nav class="mx-auto flex h-16 max-w-7xl items-center justify-between px-4 sm:px-6 lg:px-8">
          <.brand />
          <div class="hidden items-center gap-8 text-sm font-medium text-gray-600 md:flex dark:text-gray-300">
            <a href="#como-funciona" class="hover:text-gray-900 dark:hover:text-white">
              Como funciona
            </a>
            <a href="#recursos" class="hover:text-gray-900 dark:hover:text-white">Recursos</a>
            <a href="#seguranca" class="hover:text-gray-900 dark:hover:text-white">Segurança</a>
          </div>
          <div class="flex items-center gap-2">
            <.color_scheme_switch id="public-scheme" variant="toggle" />
            <.button to={~p"/login"} link_type="live_redirect" variant="ghost" color="gray">
              Entrar
            </.button>
            <.button
              to={~p"/login"}
              link_type="live_redirect"
              class="hidden sm:inline-flex"
              icon="hero-arrow-right"
              icon_placement="right"
            >
              Começar
            </.button>
          </div>
        </nav>
      </header>

      <main class="flex-1">
        {render_slot(@inner_block)}
      </main>

      <footer :if={@nav} class="border-t border-gray-200 dark:border-gray-800">
        <div class="mx-auto flex max-w-7xl flex-col items-center justify-between gap-4 px-4 py-8 text-sm text-gray-500 sm:flex-row sm:px-6 lg:px-8 dark:text-gray-400">
          <.brand size="sm" />
          <p>Powered by Claude · O merge e o deploy continuam com você.</p>
        </div>
      </footer>

      <.toast_group flash={@flash} position="top-right" />
      <.connection_status />
    </div>
    """
  end

  @doc """
  The signed-in app shell: collapsible sidebar, top bar and page content.

  ## Examples

      <Layouts.app flash={@flash} user={@user} active={:board} title="Board">
        <p>Content</p>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :user, :map, required: true, doc: "the signed-in user (name, email, org)"
  attr :active, :atom, required: true, doc: "the sidebar item to highlight"
  attr :title, :string, required: true, doc: "the page title shown in the top bar"
  attr :pending_decisions, :integer, default: 0, doc: "badge on the decisions item"

  slot :actions, doc: "buttons rendered on the right of the top bar"
  slot :inner_block, required: true

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <.sidebar_shell for="app-sidebar" class="min-h-screen bg-gray-50 dark:bg-gray-950">
      <:sidebar>
        <.sidebar_nav id="app-sidebar" label="Navegação principal" collapsible="icon">
          <:header>
            <.brand compact />
          </:header>

          <.sidebar_group label="Pipeline">
            <.sidebar_item
              label="Board"
              path={~p"/app"}
              icon="hero-view-columns"
              link_type="live_redirect"
              active={@active == :board}
            />
            <.sidebar_item
              label="Decisões"
              path={~p"/app"}
              icon="hero-hand-raised"
              badge={if @pending_decisions > 0, do: Integer.to_string(@pending_decisions)}
              link_type="live_redirect"
            />
            <.sidebar_item label="Tarefas" path={~p"/app"} icon="hero-queue-list" />
            <.sidebar_item label="Pull requests" path={~p"/app"} icon="hero-arrow-up-tray" />
          </.sidebar_group>

          <.sidebar_group label="Infraestrutura">
            <.sidebar_item label="Executores" path={~p"/app"} icon="hero-server-stack" />
            <.sidebar_item label="Pipelines" path={~p"/app"} icon="hero-squares-2x2" />
            <.sidebar_item label="Uso e limites" path={~p"/app"} icon="hero-chart-bar" />
          </.sidebar_group>

          <.sidebar_group label="Organização">
            <.sidebar_item label="Projetos" path={~p"/app"} icon="hero-folder" />
            <.sidebar_item label="Membros" path={~p"/app"} icon="hero-users" />
            <.sidebar_item label="Configurações" path={~p"/app"} icon="hero-cog-6-tooth" />
          </.sidebar_group>

          <:footer>
            <.sidebar_item
              label="Sair"
              path={~p"/"}
              icon="hero-arrow-left-start-on-rectangle"
            />
          </:footer>
        </.sidebar_nav>
      </:sidebar>

      <header class="sticky top-0 z-20 flex h-16 items-center gap-3 border-b border-gray-200 bg-white/80 px-4 backdrop-blur sm:px-6 dark:border-gray-800 dark:bg-gray-950/80">
        <.sidebar_trigger for="app-sidebar" target="mobile" class="md:hidden" />
        <.sidebar_trigger for="app-sidebar" target="collapse" class="hidden md:inline-flex" />
        <div class="min-w-0">
          <p class="truncate text-xs text-gray-500 dark:text-gray-400">{@user.org}</p>
          <h1 class="truncate text-base font-semibold text-gray-900 dark:text-white">{@title}</h1>
        </div>
        <div class="ml-auto flex items-center gap-2">
          {render_slot(@actions)}
          <.color_scheme_switch id="app-scheme" variant="dropdown" />
          <.user_dropdown_menu
            current_user_name={@user.name}
            current_user_email={@user.email}
            user_menu_items={[
              %{path: ~p"/app", icon: "hero-user-circle", label: "Perfil"},
              %{path: ~p"/app", icon: "hero-cog-6-tooth", label: "Configurações"},
              %{path: ~p"/", icon: "hero-arrow-left-start-on-rectangle", label: "Sair"}
            ]}
          />
        </div>
      </header>

      <main class="px-4 py-6 sm:px-6 lg:px-8">
        {render_slot(@inner_block)}
      </main>

      <.toast_group flash={@flash} position="bottom-right" />
      <.connection_status />
    </.sidebar_shell>
    """
  end

  @doc "The product mark: logo glyph and name."
  attr :size, :string, default: "md", values: ["sm", "md"]
  attr :compact, :boolean, default: false, doc: "glyph and name sized for the sidebar"

  @spec brand(map()) :: Phoenix.LiveView.Rendered.t()
  def brand(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="flex items-center gap-2.5">
      <span class={[
        "inline-flex shrink-0 items-center justify-center rounded-lg bg-gradient-to-br from-primary-500 to-secondary-500 text-white shadow-sm",
        if(@size == "sm", do: "size-7", else: "size-8")
      ]}>
        <.icon name="hero-cube-transparent" class="size-5" />
      </span>
      <span class={[
        "font-semibold tracking-tight text-gray-900 dark:text-white",
        @compact && "pc-sidebar__brand",
        if(@size == "sm", do: "text-sm", else: "text-base")
      ]}>
        Control Plane
      </span>
    </.link>
    """
  end

  @doc """
  A banner shown while the LiveView socket is disconnected, hidden otherwise.
  """
  @spec connection_status(map()) :: Phoenix.LiveView.Rendered.t()
  def connection_status(assigns) do
    ~H"""
    <div
      id="connection-status"
      class="fixed inset-x-0 bottom-4 z-50 mx-auto w-fit"
      phx-disconnected={JS.remove_attribute("hidden", to: "#connection-status")}
      phx-connected={JS.set_attribute({"hidden", ""}, to: "#connection-status")}
      hidden
    >
      <.alert color="warning" with_icon>
        Conexão perdida. Tentando reconectar…
      </.alert>
    </div>
    """
  end
end
