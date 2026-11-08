defmodule PipeMaestroWeb.PageHeader do
  @moduledoc """
  The parts of the top bar a page fills in: the arrow back to the parent page,
  the page's actions and, in the page body, the bar that holds its filters.

  The top bar is one row at every width. A page hands its actions to the layout
  as `<:action>` entries (declared by `action_slot/0`), never as markup:
  `page_actions/1` shows a single action as a button and two or more as one
  "Ações" button that opens a menu. Each action keeps its `testid` either way.
  """
  use Phoenix.Component
  use PetalComponents

  alias Phoenix.LiveView.JS

  @menu_id "page-actions-menu"

  @doc """
  Declares the `:action` slot on a component that renders `page_actions/1`
  (`Layouts.app/1`, `Layouts.backoffice/1`), with the attributes every action
  takes.
  """
  defmacro action_slot do
    quote do
      slot :action,
        doc: "an action of the page: one renders as a button, two or more as the \"Ações\" menu" do
        attr :label, :string, required: true

        attr :icon, :string,
          required: true,
          doc: "a Heroicon; alone it stands for the action on a phone"

        attr :testid, :string,
          doc: "the action's data-testid, the same in the button and in the menu"

        attr :navigate, :string, doc: "a path to navigate to (a live redirect)"
        attr :patch, :string, doc: "a path to patch to, in the same LiveView"
        attr :on_click, :string, doc: "the event pushed to the LiveView"
        attr :value, :map, doc: "the event's payload"
        attr :confirm, :string, doc: "a question confirmed before the event"
        attr :primary, :boolean, doc: "solid when it is the page's only action (create, connect)"
        attr :danger, :boolean, doc: "destroys or stops something: red, and last in the menu"
        attr :disabled, :boolean
      end
    end
  end

  @doc """
  The page's actions on the right of the top bar: nothing without actions, a
  button for one (its label hidden on a phone, the icon standing for it) and
  an "Ações" menu for two or more, the dangerous ones last after a separator.

  ## Examples

      <.page_actions action={@action} />
  """
  attr :action, :list, required: true, doc: "the `:action` entries the page gave the layout"

  @spec page_actions(map()) :: Phoenix.LiveView.Rendered.t()
  def page_actions(%{action: []} = assigns), do: ~H""

  def page_actions(%{action: [action]} = assigns) do
    assigns = assign(assigns, :entry, action)

    ~H"""
    <div class="flex shrink-0 items-center" data-testid="page-actions">
      <.button
        size="sm"
        variant={single_variant(@entry)}
        color={single_color(@entry)}
        icon={@entry.icon}
        link_type={link_type(@entry)}
        to={@entry[:navigate] || @entry[:patch]}
        phx-click={@entry[:on_click] && JS.push(@entry.on_click, value: @entry[:value] || %{})}
        data-confirm={@entry[:confirm]}
        disabled={@entry[:disabled] || false}
        title={@entry.label}
        aria-label={@entry.label}
        data-testid={@entry[:testid]}
      >
        <span class="hidden sm:inline">{@entry.label}</span>
      </.button>
    </div>
    """
  end

  def page_actions(assigns) do
    {danger, safe} = Enum.split_with(assigns.action, &(&1[:danger] || false))
    assigns = assign(assigns, safe: safe, danger: danger, menu_id: @menu_id)

    ~H"""
    <div class="flex shrink-0 items-center" data-testid="page-actions">
      <.dropdown
        id="page-actions"
        options_container_id={@menu_id}
        side="bottom"
        align="end"
        trigger_class="pc-button pc-button--gray-outline pc-button--sm pc-button--with-icon"
        menu_items_wrapper_class="w-60"
      >
        <:trigger_element>
          <span
            class="inline-flex items-center gap-1.5"
            title="Ações"
            data-testid="page-actions-trigger"
          >
            <.icon name="hero-ellipsis-horizontal" class="pc-button__spinner-icon--sm" />
            <span class="hidden sm:inline">Ações</span>
            <.icon name="hero-chevron-down-mini" class="hidden size-4 sm:inline" />
          </span>
        </:trigger_element>
        <.menu_action :for={entry <- @safe} entry={entry} menu_id={@menu_id} />
        <.dropdown_menu_separator :if={@safe != [] and @danger != []} />
        <.menu_action :for={entry <- @danger} entry={entry} menu_id={@menu_id} />
      </.dropdown>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :menu_id, :string, required: true

  # An action inside the menu. A path stays a real link (it opens in a new tab
  # too). Each one closes the menu as it acts: a patch or an event keeps the
  # same LiveView, and the menu would stay open over it.
  defp menu_action(assigns) do
    ~H"""
    <.dropdown_menu_item
      link_type={link_type(@entry)}
      to={@entry[:navigate] || @entry[:patch]}
      disabled={@entry[:disabled] || false}
      class={@entry[:danger] && "text-danger-600! dark:text-danger-400!"}
      phx-click={menu_click(@entry, @menu_id)}
      data-confirm={@entry[:confirm]}
      data-testid={@entry[:testid]}
    >
      <.icon name={@entry.icon} class="size-5" />
      {@entry.label}
    </.dropdown_menu_item>
    """
  end

  defp menu_click(entry, menu_id) do
    hide = JS.hide(to: "##{menu_id}")

    if entry[:on_click],
      do: JS.push(hide, entry.on_click, value: entry[:value] || %{}),
      else: hide
  end

  defp link_type(%{navigate: path}) when is_binary(path), do: "live_redirect"
  defp link_type(%{patch: path}) when is_binary(path), do: "live_patch"
  defp link_type(_entry), do: "button"

  defp single_variant(entry) do
    cond do
      entry[:danger] -> "outline"
      entry[:primary] -> "solid"
      true -> "outline"
    end
  end

  defp single_color(entry) do
    cond do
      entry[:danger] -> "danger"
      entry[:primary] -> "primary"
      true -> "gray"
    end
  end

  @doc """
  The arrow back to the parent page, before the title. Its label is the
  parent's name, read by screen readers and shown on hover.

  ## Examples

      <.back_link back={%{to: ~p"/w/acme/tasks", label: "Tarefas", testid: "back-to-tasks"}} />
  """
  attr :back, :map,
    required: true,
    doc: "`to` (the parent page), `label` (its name) and an optional `testid`"

  @spec back_link(map()) :: Phoenix.LiveView.Rendered.t()
  def back_link(assigns) do
    ~H"""
    <.icon_button
      link_type="live_redirect"
      to={@back.to}
      size="sm"
      color="gray"
      class="shrink-0"
      title={@back.label}
      aria-label={"Voltar para #{@back.label}"}
      data-testid={@back[:testid] || "page-back"}
    >
      <.icon name="hero-arrow-left" class="size-5" />
    </.icon_button>
    """
  end

  @doc """
  The bar at the top of a page's content that holds its filters (a segmented
  choice, a select), which the top bar has no room for.

  ## Examples

      <.filter_bar>
        <.button size="sm">Todas</.button>
      </.filter_bar>
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  @spec filter_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def filter_bar(assigns) do
    ~H"""
    <div class={["mb-4 flex flex-wrap items-center gap-2", @class]} data-testid="filter-bar" {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
