defmodule PipeMaestroWeb.ListComponents do
  @moduledoc """
  Every listing of records is a column of cards, the same on a wide screen and
  on a phone (ADR 0052): `record_list/1` holds them, `record_card/1` is one
  record, `record_metric/1` a number of it and `load_more/1` asks for the next
  page.

  A card is laid out in places each screen fills. Its head holds what leads
  it (an icon, an avatar, its kind), its title, the badges beside it (its
  status), a line of facts under it and its metrics, which sit to the right
  once the card is wide (a container query) and under the title before
  that. Under the head, as wide as the card, come its body (a summary, a
  form, a diagram) and its actions. A card with a link is
  clickable as a whole: the title's link stretches over it, and whatever is
  interactive inside sits above that link.
  """
  use Phoenix.Component

  import PetalComponents.Button, only: [button: 1]
  import PetalComponents.Empty, only: [empty: 1]
  import PetalComponents.Icon, only: [icon: 1]

  @tones [nil, :running, :awaiting, :danger, :success]

  @doc """
  The border and ring that call attention to a card or a place: it runs,
  waits on a person, failed, or is ready.
  """
  @spec attention_class(atom()) :: String.t()
  def attention_class(:running),
    do: "border-info-400 ring-2 ring-info-400/30 dark:border-info-600"

  def attention_class(:awaiting),
    do: "border-warning-400 ring-2 ring-warning-400/40 dark:border-warning-600"

  def attention_class(:danger),
    do: "border-danger-300 ring-2 ring-danger-400/20 dark:border-danger-700"

  def attention_class(:success),
    do: "border-success-400 ring-2 ring-success-400/30 dark:border-success-600"

  def attention_class(nil), do: "border-gray-200 dark:border-gray-800"

  attr :id, :string, default: nil
  attr :testid, :string, default: nil
  attr :empty, :boolean, default: false, doc: "no records: the `:empty_state` slot shows instead"
  attr :class, :any, default: nil
  slot :inner_block, required: true, doc: "the `record_card/1`s"
  slot :empty_state, doc: "what shows without records (`record_empty/1`)"

  @doc "A column of records, one card each, or what shows without them."
  @spec record_list(map()) :: Phoenix.LiveView.Rendered.t()
  def record_list(assigns) do
    ~H"""
    {if @empty, do: render_slot(@empty_state)}
    <ul :if={!@empty} id={@id} role="list" class={["space-y-3", @class]} data-testid={@testid}>
      {render_slot(@inner_block)}
    </ul>
    """
  end

  attr :id, :string, default: nil
  attr :testid, :string, default: nil
  attr :navigate, :string, default: nil, doc: "the record's page: the card is its link"
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :click, :any, default: nil, doc: "an event the card sends instead of a link"
  attr :click_value, :any, default: nil, doc: "the event's `phx-value-id`"
  attr :click_target, :any, default: nil, doc: "the event's `phx-target`"
  attr :link_testid, :string, default: nil, doc: "the title's link or button"
  attr :link_attrs, :map, default: %{}, doc: "more attributes of the title's link or button"
  attr :tone, :atom, default: nil, values: @tones
  attr :dense, :boolean, default: false, doc: "smaller, for a narrow column or a short list"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :leading, doc: "what leads the card: an icon, an avatar, its kind"
  slot :title, required: true
  slot :badge, doc: "beside the title: its status"

  slot :meta, doc: "the line of facts under the title" do
    attr :interactive, :boolean, doc: "holds links of its own"
  end

  slot :body, doc: "the record's own content" do
    attr :interactive, :boolean, doc: "holds links, buttons or a form"
  end

  slot :aside, doc: "its metrics (`record_metric/1`)"
  slot :actions, doc: "its buttons"

  @doc """
  One record as a card. With `navigate`, `patch` or `href` the card is its
  link, and with `click` it sends an event; the title carries either,
  stretched over the card.
  """
  @spec record_card(map()) :: Phoenix.LiveView.Rendered.t()
  def record_card(assigns) do
    assigns =
      assign(assigns,
        linked: !!(assigns.navigate || assigns.patch || assigns.href),
        clickable: !is_nil(assigns.click)
      )

    ~H"""
    <li
      id={@id}
      class={[
        "@container relative rounded-xl border bg-white transition dark:bg-gray-900",
        if(@dense, do: "px-3 py-2.5", else: "px-4 py-3"),
        attention_class(@tone),
        (@linked or @clickable) &&
          "hover:border-primary-400 hover:shadow-sm dark:hover:border-primary-500",
        @class
      ]}
      data-testid={@testid}
      {@rest}
    >
      <div class="flex items-start gap-3">
        <div :if={@leading != []} class="shrink-0">{render_slot(@leading)}</div>
        <div class={[
          "flex min-w-0 flex-1 flex-col gap-2",
          !@dense && "@2xl:flex-row @2xl:items-start @2xl:gap-6"
        ]}>
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
              <.link
                :if={@linked}
                navigate={@navigate}
                patch={@patch}
                href={@href}
                class={[
                  "min-w-0 break-words font-semibold text-gray-900 after:absolute after:inset-0 after:rounded-xl focus:outline-none focus-visible:after:ring-2 focus-visible:after:ring-primary-500 dark:text-white",
                  if(@dense, do: "text-sm", else: "text-base")
                ]}
                data-testid={@link_testid}
                {@link_attrs}
              >
                {render_slot(@title)}
              </.link>
              <button
                :if={@clickable}
                type="button"
                phx-click={@click}
                phx-value-id={@click_value}
                phx-target={@click_target}
                class={[
                  "min-w-0 break-words text-left font-semibold text-gray-900 after:absolute after:inset-0 after:rounded-xl focus:outline-none focus-visible:after:ring-2 focus-visible:after:ring-primary-500 dark:text-white",
                  if(@dense, do: "text-sm", else: "text-base")
                ]}
                data-testid={@link_testid}
                {@link_attrs}
              >
                {render_slot(@title)}
              </button>
              <span
                :if={!@linked and !@clickable}
                class={[
                  "min-w-0 break-words font-semibold text-gray-900 dark:text-white",
                  if(@dense, do: "text-sm", else: "text-base")
                ]}
              >
                {render_slot(@title)}
              </span>
              {render_slot(@badge)}
            </div>
            <div
              :for={meta <- @meta}
              class={[
                "mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-gray-500 dark:text-gray-400",
                meta[:interactive] && "relative z-10"
              ]}
            >
              {render_slot(meta)}
            </div>
          </div>
          <div
            :if={@aside != []}
            class={[
              "flex shrink-0 flex-wrap items-center gap-x-4 gap-y-1 text-xs text-gray-500 dark:text-gray-400",
              !@dense && "@2xl:max-w-xs @2xl:flex-col @2xl:items-end @2xl:text-right"
            ]}
          >
            {render_slot(@aside)}
          </div>
        </div>
        <.icon
          :if={(@linked or @clickable) and @actions == []}
          name="hero-chevron-right"
          class="mt-1 size-4 shrink-0 text-gray-400"
        />
      </div>
      <div
        :for={body <- @body}
        class={[
          "mt-3 text-sm text-gray-700 dark:text-gray-300",
          body[:interactive] && "relative z-10"
        ]}
      >
        {render_slot(body)}
      </div>
      <div
        :if={@actions != []}
        class="relative z-10 mt-3 flex flex-wrap items-center justify-end gap-2 border-t border-gray-100 pt-3 dark:border-gray-800"
      >
        {render_slot(@actions)}
      </div>
    </li>
    """
  end

  attr :label, :string, default: nil, doc: "what the number is, when the icon does not say it"
  attr :icon, :string, default: nil
  attr :title, :string, default: nil, doc: "what the number is, on hover"
  attr :testid, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc "One number of a record, with its icon or what it is: for a card's `:aside`."
  @spec record_metric(map()) :: Phoenix.LiveView.Rendered.t()
  def record_metric(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1", @class]} title={@title || @label}>
      <.icon :if={@icon} name={@icon} class="size-3.5 shrink-0 text-gray-400 dark:text-gray-500" />
      <span :if={@label} class="text-gray-400 dark:text-gray-500">{@label}</span>
      <span class="font-medium text-gray-700 dark:text-gray-200" data-testid={@testid}>
        {render_slot(@inner_block)}
      </span>
    </span>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, default: nil, doc: "what the fact is, on hover"
  attr :mono, :boolean, default: false, doc: "a path, a host or an address"
  attr :testid, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc "One fact of a record with its icon (its project, its runner, who, when): for a card's `:meta`."
  @spec record_fact(map()) :: Phoenix.LiveView.Rendered.t()
  def record_fact(assigns) do
    ~H"""
    <span class={["inline-flex min-w-0 items-center gap-1", @class]} title={@title}>
      <.icon name={@icon} class="size-3.5 shrink-0 text-gray-400 dark:text-gray-500" />
      <span class={["truncate", @mono && "font-mono"]} data-testid={@testid}>
        {render_slot(@inner_block)}
      </span>
    </span>
    """
  end

  attr :icon, :string, required: true
  attr :color, :string, default: "gray", values: ~w(gray primary info warning danger success)
  attr :small, :boolean, default: false, doc: "for a dense card"
  attr :testid, :string, default: nil

  @doc "What leads a card: its kind as an icon on a tile."
  @spec record_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def record_icon(assigns) do
    ~H"""
    <span
      class={[
        "flex shrink-0 items-center justify-center rounded-lg ring-1 ring-inset",
        if(@small, do: "size-8", else: "size-10"),
        icon_color(@color)
      ]}
      data-testid={@testid}
    >
      <.icon name={@icon} class={if @small, do: "size-4", else: "size-5"} />
    </span>
    """
  end

  defp icon_color("gray"),
    do:
      "bg-gray-100 text-gray-500 ring-gray-200 dark:bg-gray-800 dark:text-gray-400 dark:ring-gray-700"

  defp icon_color("primary"),
    do:
      "bg-primary-50 text-primary-600 ring-primary-100 dark:bg-primary-950 dark:text-primary-300 dark:ring-primary-900"

  defp icon_color("info"),
    do:
      "bg-info-50 text-info-600 ring-info-100 dark:bg-info-950 dark:text-info-300 dark:ring-info-900"

  defp icon_color("warning"),
    do:
      "bg-warning-50 text-warning-600 ring-warning-100 dark:bg-warning-950 dark:text-warning-300 dark:ring-warning-900"

  defp icon_color("danger"),
    do:
      "bg-danger-50 text-danger-600 ring-danger-100 dark:bg-danger-950 dark:text-danger-300 dark:ring-danger-900"

  defp icon_color("success"),
    do:
      "bg-success-50 text-success-600 ring-success-100 dark:bg-success-950 dark:text-success-300 dark:ring-success-900"

  attr :more, :boolean, required: true, doc: "there are more records to load"
  attr :event, :string, default: "load_more"
  attr :target, :any, default: nil
  attr :testid, :string, required: true

  @doc "The next page of a listing, asked for by a click."
  @spec load_more(map()) :: Phoenix.LiveView.Rendered.t()
  def load_more(assigns) do
    ~H"""
    <div :if={@more} class="mt-4 flex justify-center">
      <.button
        size="sm"
        variant="outline"
        color="gray"
        icon="hero-chevron-down"
        phx-click={@event}
        phx-target={@target}
        data-testid={@testid}
      >
        Carregar mais
      </.button>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :icon, :string, default: "hero-inbox"
  attr :testid, :string, required: true
  slot :actions

  @doc "What a listing says without records."
  @spec record_empty(map()) :: Phoenix.LiveView.Rendered.t()
  def record_empty(assigns) do
    ~H"""
    <.empty title={@title} description={@description} data-testid={@testid}>
      <:icon><.icon name={@icon} class="size-8" /></:icon>
      <:actions :if={@actions != []}>{render_slot(@actions)}</:actions>
    </.empty>
    """
  end
end
