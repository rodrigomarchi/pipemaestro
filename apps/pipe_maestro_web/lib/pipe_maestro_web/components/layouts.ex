defmodule PipeMaestroWeb.Layouts do
  @moduledoc """
  The page chrome: the root HTML skeleton, the public layout (landing and sign
  in) and the signed-in app shell with its sidebar.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.BrandComponents, only: [logo_mark: 1]
  import PipeMaestroWeb.PageHeader

  alias PipeMaestro.Version

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
    <div class="relative flex min-h-screen flex-col bg-white dark:bg-gray-950">
      <header
        :if={@nav}
        class="sticky top-0 z-30 border-b border-gray-200/70 bg-white/80 backdrop-blur dark:border-gray-800/70 dark:bg-gray-950/80"
      >
        <nav class="mx-auto flex h-16 max-w-7xl items-center justify-between px-4 sm:px-6 lg:px-8">
          <.brand />
          <div class="hidden items-center gap-8 text-sm font-medium text-gray-600 md:flex dark:text-gray-300">
            <a
              href="#produto"
              class="hover:text-gray-900 dark:hover:text-white"
              data-testid="nav-product"
            >
              Produto
            </a>
            <a href="#como-funciona" class="hover:text-gray-900 dark:hover:text-white">
              Como funciona
            </a>
            <a href="#recursos" class="hover:text-gray-900 dark:hover:text-white">Recursos</a>
            <a href="#seguranca" class="hover:text-gray-900 dark:hover:text-white">Segurança</a>
          </div>
          <div class="flex items-center gap-2">
            <.color_scheme_switch id="public-scheme" variant="toggle" />
            <.button
              to={~p"/login"}
              link_type="live_redirect"
              variant="ghost"
              color="gray"
              data-testid="nav-login"
            >
              Entrar
            </.button>
            <.button
              to={~p"/login"}
              link_type="live_redirect"
              class="hidden sm:inline-flex"
              icon="hero-arrow-right"
              icon_placement="right"
              data-testid="nav-get-started"
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
          <.brand size="sm" testid="footer-brand" />
          <p>Powered by Claude · O merge e o deploy continuam com você.</p>
          <.app_version />
        </div>
      </footer>
      <%!-- Pages without the navigation fill the screen themselves: the version sits over their bottom. --%>
      <footer :if={!@nav} class="pointer-events-none absolute inset-x-0 bottom-4 text-center">
        <.app_version />
      </footer>

      <.toast_group flash={@flash} position="top-center" data-testid="toasts" />
      <.connection_status />
    </div>
    """
  end

  @doc """
  The signed-in app shell of a workspace: a sidebar that closes to a rail of
  icons (the choice kept in the browser, `assets/js/sidebar.js`, and closed on
  its own on a page with `focus`) and holds the account menu and the color
  scheme at its foot; a one-row top bar with the arrow back, the workspace
  switcher, the title and its status, the page's actions and the bell; and
  page content.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} workspaces={@workspaces} active={:board} title="Board">
        <p>Content</p>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, PipeMaestro.Accounts.Scope,
    required: true,
    doc: "the signed-in user and the current workspace"

  attr :workspaces, :list, default: [], doc: "every workspace of the user, for the switcher"
  attr :active, :atom, required: true, doc: "the sidebar item to highlight"
  attr :title, :string, required: true, doc: "the page title shown in the top bar"
  attr :pending_decisions, :integer, default: 0, doc: "badge on the decisions item"

  attr :notification_center, :map,
    default: %{unread: 0, active: []},
    doc:
      "the bell's unread count and what runs now (`PipeMaestroWeb.NotificationHooks`); every workspace page hands it on"

  attr :focus, :boolean,
    default: false,
    doc: "the page follows work in progress: the sidebar closes to its icons to give it room"

  attr :back, :map,
    default: nil,
    doc: "the parent page for the arrow before the title: `to`, `label` and `testid`"

  slot :status,
    doc:
      "badges beside the title (a record's status, a key number), seen from every tab; hidden on a phone"

  action_slot()
  slot :inner_block, required: true

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    assigns = assign(assigns, :home, ~p"/w/#{assigns.current_scope.workspace.slug}")

    ~H"""
    <.sidebar_shell for="app-sidebar" class="min-h-screen bg-gray-50 dark:bg-gray-950">
      <:sidebar>
        <.sidebar_nav
          id="app-sidebar"
          label="Navegação principal"
          collapsible="icon"
          collapsed={@focus}
          phx-hook="Sidebar"
          phx-mounted={JS.ignore_attributes(["data-collapsed"])}
          data-focus={to_string(@focus)}
          data-testid="app-sidebar"
        >
          <:header>
            <.brand compact />
          </:header>

          <.sidebar_group label="Pipeline">
            <.sidebar_item
              label="Board"
              path={@home}
              icon="hero-view-columns"
              link_type="live_redirect"
              active={@active == :board}
              data-testid="sidebar-board"
            />
            <.sidebar_item
              label="Decisões"
              path={@home <> "/decisions"}
              icon="hero-hand-raised"
              badge={if @pending_decisions > 0, do: Integer.to_string(@pending_decisions)}
              link_type="live_redirect"
              active={@active == :decisions}
              data-testid="sidebar-decisions"
            />
            <.sidebar_item
              label="Propostas"
              path={@home <> "/proposals"}
              icon="hero-cpu-chip"
              link_type="live_redirect"
              active={@active == :proposals}
              data-testid="sidebar-proposals"
            />
            <.sidebar_item
              label="Execuções"
              path={@home <> "/jobs"}
              icon="hero-command-line"
              link_type="live_redirect"
              active={@active == :jobs}
              data-testid="sidebar-jobs"
            />
            <.sidebar_item
              label="Tarefas"
              path={@home <> "/tasks"}
              icon="hero-queue-list"
              link_type="live_redirect"
              active={@active == :tasks}
              data-testid="sidebar-tasks"
            />
            <.sidebar_item
              label="Pull requests"
              path={@home <> "/pull-requests"}
              icon="hero-arrow-up-tray"
              link_type="live_redirect"
              active={@active == :pull_requests}
              data-testid="sidebar-pull-requests"
            />
          </.sidebar_group>

          <.sidebar_group label="Infraestrutura">
            <.sidebar_item
              label="Executores"
              path={@home <> "/runners"}
              icon="hero-server-stack"
              link_type="live_redirect"
              active={@active == :runners}
              data-testid="sidebar-runners"
            />
            <.sidebar_item
              label="Projetos"
              path={@home <> "/projects"}
              icon="hero-folder"
              link_type="live_redirect"
              active={@active == :projects}
              data-testid="sidebar-projects"
            />
            <.sidebar_item
              label="Pipelines"
              path={@home <> "/pipelines"}
              icon="hero-squares-2x2"
              link_type="live_redirect"
              active={@active == :pipelines}
              data-testid="sidebar-pipelines"
            />
            <.sidebar_item
              label="Uso e limites"
              path={@home <> "/usage"}
              icon="hero-chart-bar"
              link_type="live_redirect"
              active={@active == :usage}
              data-testid="sidebar-usage"
            />
            <.sidebar_item
              :if={can?(@current_scope, :manage_runners)}
              label="Auditoria"
              path={@home <> "/audit"}
              icon="hero-clipboard-document-list"
              link_type="live_redirect"
              active={@active == :audit}
              data-testid="sidebar-audit"
            />
            <.sidebar_item
              :if={can?(@current_scope, :manage_runners)}
              label="Segredos"
              path={@home <> "/secrets"}
              icon="hero-key"
              link_type="live_redirect"
              active={@active == :secrets}
              data-testid="sidebar-secrets"
            />
            <.sidebar_item
              :if={can?(@current_scope, :manage_integrations)}
              label="Integrações"
              path={@home <> "/integrations"}
              icon="hero-link"
              link_type="live_redirect"
              active={@active == :integrations}
              data-testid="sidebar-integrations"
            />
          </.sidebar_group>

          <:footer>
            <.sidebar_toggle for="app-sidebar" data-testid="sidebar-toggle" />
            <.sidebar_account
              name={@current_scope.user.name}
              email={@current_scope.user.email}
              scheme_id="app-scheme"
            >
              <.dropdown_menu_item
                link_type="a"
                to={~p"/workspaces"}
                data-testid="account-switch-workspace"
              >
                <.icon name="hero-squares-2x2" class="size-5" /> Trocar de workspace
              </.dropdown_menu_item>
              <.logout_button to={~p"/logout"} data-testid="account-logout" />
            </.sidebar_account>
            <.app_version class="pc-sidebar__brand block px-3 pt-2" />
          </:footer>
        </.sidebar_nav>
      </:sidebar>

      <header class={header_class()} data-testid="top-bar">
        <.sidebar_trigger
          for="app-sidebar"
          target="mobile"
          class="md:hidden"
          data-testid="sidebar-open"
        />
        <.sidebar_trigger
          for="app-sidebar"
          target="collapse"
          class="hidden md:inline-flex"
          data-testid="sidebar-collapse"
        />
        <.back_link :if={@back} back={@back} />
        <div class="min-w-0 flex-1">
          <.workspace_switcher current={@current_scope.workspace} workspaces={@workspaces} />
          <div class="flex min-w-0 items-center gap-2">
            <h1
              class="truncate text-base font-semibold text-gray-900 dark:text-white"
              data-testid="page-title"
            >
              {@title}
            </h1>
            <div :if={@status != []} class="hidden shrink-0 items-center gap-1.5 sm:flex">
              {render_slot(@status)}
            </div>
          </div>
        </div>
        <.page_actions action={@action} />
        <.live_component
          module={PipeMaestroWeb.NotificationCenter}
          id="notification-center"
          center={@notification_center}
          current_scope={@current_scope}
        />
      </header>

      <main class="px-4 py-6 sm:px-6 lg:px-8">
        {render_slot(@inner_block)}
      </main>

      <.toast_group flash={@flash} position="bottom-right" data-testid="toasts" />
      <.connection_status />
    </.sidebar_shell>
    """
  end

  attr :current, :map, required: true
  attr :workspaces, :list, required: true

  # The board is a live_session of its own per workspace mount, so switching
  # workspaces is a full navigation.
  defp workspace_switcher(%{workspaces: [_, _ | _]} = assigns) do
    ~H"""
    <.dropdown id="workspace-switcher" placement="right" trigger_class="!p-0">
      <:trigger_element>
        <span
          class="flex items-center gap-1 text-xs font-medium text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-white"
          data-testid="workspace-switcher-trigger"
        >
          <span data-testid="current-workspace">{@current.name}</span>
          <.icon name="hero-chevron-up-down-micro" class="size-3.5" />
        </span>
      </:trigger_element>
      <.dropdown_menu_label>Seus workspaces</.dropdown_menu_label>
      <.dropdown_menu_item
        :for={workspace <- @workspaces}
        link_type="a"
        to={~p"/w/#{workspace.slug}"}
        data-testid={"workspace-switcher-item-#{workspace.slug}"}
      >
        <.icon
          name={if workspace.id == @current.id, do: "hero-check", else: "hero-building-office"}
          class="size-4"
        />
        {workspace.name}
      </.dropdown_menu_item>
    </.dropdown>
    """
  end

  defp workspace_switcher(assigns) do
    ~H"""
    <p class="truncate text-xs text-gray-500 dark:text-gray-400" data-testid="current-workspace">
      {@current.name}
    </p>
    """
  end

  @doc """
  The backoffice shell for platform operators: its own sidebar and an amber
  "Backoffice" mark, so it is never mistaken for a customer workspace.

  ## Examples

      <Layouts.backoffice flash={@flash} current_operator={@current_operator} active={:workspaces} title="Workspaces">
        <p>Content</p>
      </Layouts.backoffice>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_operator, :map, required: true, doc: "the signed-in operator"

  attr :active, :atom,
    required: true,
    values: [:workspaces, :users, :operators],
    doc: "the sidebar item to highlight"

  attr :title, :string, required: true, doc: "the page title shown in the top bar"

  attr :back, :map,
    default: nil,
    doc: "the parent page for the arrow before the title: `to`, `label` and `testid`"

  action_slot()
  slot :inner_block, required: true

  @spec backoffice(map()) :: Phoenix.LiveView.Rendered.t()
  def backoffice(assigns) do
    ~H"""
    <.sidebar_shell for="backoffice-sidebar" class="min-h-screen bg-gray-50 dark:bg-gray-950">
      <:sidebar>
        <.sidebar_nav id="backoffice-sidebar" label="Backoffice" collapsible="icon">
          <:header>
            <.brand compact />
          </:header>

          <.sidebar_group label="Clientes">
            <.sidebar_item
              label="Workspaces"
              data-testid="sidebar-workspaces"
              path={~p"/backoffice/workspaces"}
              icon="hero-building-office-2"
              link_type="live_redirect"
              active={@active == :workspaces}
            />
            <.sidebar_item
              label="Usuários"
              data-testid="sidebar-users"
              path={~p"/backoffice/users"}
              icon="hero-users"
              link_type="live_redirect"
              active={@active == :users}
            />
          </.sidebar_group>

          <.sidebar_group label="Plataforma">
            <.sidebar_item
              label="Operadores"
              data-testid="sidebar-operators"
              path={~p"/backoffice/operators"}
              icon="hero-shield-check"
              link_type="live_redirect"
              active={@active == :operators}
            />
          </.sidebar_group>

          <:footer>
            <.sidebar_account
              name={@current_operator.name}
              email={@current_operator.email}
              scheme_id="backoffice-scheme"
            >
              <.logout_button
                to={~p"/backoffice/logout"}
                data-testid="account-logout"
              />
            </.sidebar_account>
            <.app_version class="pc-sidebar__brand block px-3 pt-2" />
          </:footer>
        </.sidebar_nav>
      </:sidebar>

      <header class={header_class()} data-testid="top-bar">
        <.sidebar_trigger for="backoffice-sidebar" target="mobile" class="md:hidden" />
        <.sidebar_trigger
          for="backoffice-sidebar"
          target="collapse"
          class="hidden md:inline-flex"
        />
        <.back_link :if={@back} back={@back} />
        <div class="min-w-0 flex-1">
          <.badge size="xs" color="warning" variant="soft" label="Backoffice" />
          <h1
            class="truncate text-base font-semibold text-gray-900 dark:text-white"
            data-testid="page-title"
          >
            {@title}
          </h1>
        </div>
        <.page_actions action={@action} />
      </header>

      <main class="px-4 py-6 sm:px-6 lg:px-8">
        {render_slot(@inner_block)}
      </main>

      <.toast_group flash={@flash} position="bottom-right" data-testid="toasts" />
      <.connection_status />
    </.sidebar_shell>
    """
  end

  # The top bar: one row at every width. The title truncates, the status
  # hides on a phone and the page's actions fold into one menu
  # (`PageHeader.page_actions/1`), so nothing ever wraps onto a second row.
  # On a phone it scrolls away with the page. The blur sits on a layer of its
  # own: a backdrop filter on the header would hold the notification panel
  # (fixed) inside it.
  defp header_class do
    "relative z-20 flex h-14 flex-nowrap items-center gap-2 border-b border-gray-200 bg-white/80 px-4 " <>
      "before:pointer-events-none before:absolute before:inset-0 before:-z-10 before:backdrop-blur before:content-[''] " <>
      "sm:gap-3 sm:px-6 md:sticky md:top-0 md:h-16 " <>
      "dark:border-gray-800 dark:bg-gray-950/80"
  end

  @doc """
  The foot of the sidebar: the signed-in account, a row with the avatar, name
  and e-mail that opens upward a menu headed by who is signed in (the inner
  block holds its actions), and the color scheme toggle beside it. On the
  icon rail only the avatar is left, the toggle under it.
  """
  attr :name, :string, required: true
  attr :email, :string, required: true
  attr :scheme_id, :string, required: true, doc: "the id of the color scheme toggle"
  slot :inner_block, required: true

  @spec sidebar_account(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar_account(assigns) do
    ~H"""
    <div class="flex items-center gap-1 md:in-data-[collapsed=true]:flex-col">
      <.dropdown
        id="account-menu"
        side="top"
        align="start"
        class="pc-user-menu--sidebar min-w-0 flex-1"
        trigger_class="pc-user-menu__row"
        menu_items_wrapper_class="w-60"
      >
        <:trigger_element>
          <.avatar
            name={@name}
            size="sm"
            random_color
            aria-hidden="true"
            data-testid="account-menu-trigger"
          />
          <span class="pc-user-menu__identity">
            <span class="pc-user-menu__name">{@name}</span>
            <span class="pc-user-menu__email">{@email}</span>
          </span>
          <%!-- The icon's own utility outranks Petal's rule that hides it on the rail. --%>
          <.icon
            name="hero-chevron-up-down"
            class="pc-dropdown__chevron md:in-data-[collapsed=true]:hidden"
          />
        </:trigger_element>
        <div class="px-3 py-2">
          <p
            class="truncate text-sm font-medium text-gray-900 dark:text-white"
            data-testid="account-name"
          >
            {@name}
          </p>
          <p class="truncate text-xs text-gray-500 dark:text-gray-400" data-testid="account-email">
            {@email}
          </p>
        </div>
        <.dropdown_menu_separator />
        {render_slot(@inner_block)}
      </.dropdown>
      <.color_scheme_switch
        id={@scheme_id}
        variant="toggle"
        light_label="Claro"
        dark_label="Escuro"
        class="shrink-0"
        data-testid="color-scheme-toggle"
      />
    </div>
    """
  end

  @doc """
  The sidebar's own button to close it to a rail of icons and open it again,
  styled as a sidebar item: "Recolher menu" with an arrow that turns around
  once closed. It toggles the same attribute as the top bar's trigger, so the
  `Sidebar` hook keeps the choice. Desktop only: on a phone the sidebar is a
  sheet.
  """
  attr :for, :string, required: true, doc: "the sidebar's id"
  attr :rest, :global

  @spec sidebar_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="pc-sidebar-item pc-sidebar-trigger--collapse hidden w-full md:flex"
      title="Recolher ou expandir o menu"
      aria-label="Recolher ou expandir o menu"
      aria-controls={@for}
      phx-click={JS.toggle_attribute({"data-collapsed", "true", "false"}, to: "##{@for}")}
      data-sidebar-toggle
      {@rest}
    >
      <.icon name="hero-chevron-double-left" class="pc-sidebar-item__icon transition-transform" />
      <span class="pc-sidebar-item__label">Recolher menu</span>
    </button>
    """
  end

  @doc """
  "Sair" as a real form posting `DELETE` to `to`, so signing out never depends
  on JavaScript turning a link into a non-GET request. Styled as a menu item.
  """
  attr :to, :string, required: true
  attr :rest, :global

  @spec logout_button(map()) :: Phoenix.LiveView.Rendered.t()
  def logout_button(assigns) do
    ~H"""
    <.form for={%{}} action={@to} method="delete" class="contents">
      <button
        type="submit"
        class="pc-dropdown__menu-item w-full"
        role="menuitem"
        {@rest}
      >
        <.icon name="hero-arrow-left-start-on-rectangle" class="size-5" /> Sair
      </button>
    </.form>
    """
  end

  @doc "The product mark: the PipeMaestro symbol (`BrandComponents.logo_mark/1`) and name."
  attr :size, :string, default: "md", values: ["sm", "md"]
  attr :compact, :boolean, default: false, doc: "glyph and name sized for the sidebar"

  attr :testid, :string,
    default: "brand",
    doc: "test id of the link; the symbol's is `<testid>-mark`"

  @spec brand(map()) :: Phoenix.LiveView.Rendered.t()
  def brand(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="flex items-center gap-2.5" data-testid={@testid}>
      <.logo_mark
        class={if(@size == "sm", do: "size-7", else: "size-8")}
        data-testid={@testid <> "-mark"}
      />
      <span class={[
        "font-semibold tracking-tight text-gray-900 dark:text-white",
        @compact && "pc-sidebar__brand",
        if(@size == "sm", do: "text-sm", else: "text-base")
      ]}>
        PipeMaestro
      </span>
    </.link>
    """
  end

  @doc "This control plane's version (`PipeMaestro.Version`), small and muted."
  attr :class, :any, default: nil

  @spec app_version(map()) :: Phoenix.LiveView.Rendered.t()
  def app_version(assigns) do
    assigns = assign(assigns, :version, Version.version())

    ~H"""
    <span
      class={["font-mono text-xs text-gray-400 dark:text-gray-500", @class]}
      title="Versão do control plane"
      data-testid="app-version"
    >
      {@version}
    </span>
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
