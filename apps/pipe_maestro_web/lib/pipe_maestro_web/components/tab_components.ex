defmodule PipeMaestroWeb.TabComponents do
  @moduledoc """
  A page split in tabs that focus on one subject each, chosen by the `aba`
  parameter of the URL (`?aba=`), so a reload or a shared link opens the same
  tab. `page_tabs/1` is the row of tabs, each a `live_patch` link with an
  optional count; `tab_panel/1` wraps a tab's content.

  A panel not chosen stays in the page, hidden: a stream inside it (a run's
  live timeline) would lose what it showed if it left the page. A screen whose
  tabs read data of their own loads only the chosen one instead
  (`PipeMaestroWeb.RunnerLive`).
  """
  use PipeMaestroWeb, :html

  @typedoc """
  A tab: its `aba` value, label and icon, and optionally a count shown beside
  the label (`nil` or 0 hides it).
  """
  @type tab ::
          {String.t(), String.t(), String.t()}
          | {String.t(), String.t(), String.t(), non_neg_integer() | nil}

  @doc "The row of tabs, `active` the one chosen and `path` the URL of a tab by its id."
  attr :tabs, :list, required: true, doc: "a list of `t:tab/0`"
  attr :active, :string, required: true
  attr :path, :any, required: true, doc: "a function from a tab's id to its URL"
  attr :testid, :string, required: true, doc: "prefix of the test ids (`<testid>-tab-<id>`)"

  @spec page_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def page_tabs(assigns) do
    assigns = assign(assigns, :tabs, Enum.map(assigns.tabs, &normalize/1))

    ~H"""
    <.tabs variant="underline" class="overflow-x-auto" data-testid={"#{@testid}-tabs"}>
      <.tab
        :for={{id, label, icon, count} <- @tabs}
        link_type="live_patch"
        to={@path.(id)}
        is_active={@active == id}
        variant="underline"
        class="whitespace-nowrap"
        data-testid={"#{@testid}-tab-#{id}"}
      >
        <.icon name={icon} class="mr-1.5 size-4" /> {label}
        <.badge
          :if={count not in [nil, 0]}
          size="xs"
          variant="soft"
          color="gray"
          label={to_string(count)}
          class="ml-1.5"
          data-testid={"#{@testid}-tab-count-#{id}"}
        />
      </.tab>
    </.tabs>
    """
  end

  @doc "A tab's content, hidden while another tab is chosen."
  attr :id, :string, required: true
  attr :active, :string, required: true
  attr :testid, :string, required: true, doc: "prefix of the test id (`<testid>-panel-<id>`)"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @spec tab_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def tab_panel(assigns) do
    ~H"""
    <div class={[@id != @active && "hidden", @class]} data-testid={"#{@testid}-panel-#{@id}"}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The tab named by `param` when it is one of `tabs`, else `default`."
  @spec chosen([tab()], String.t() | nil, String.t()) :: String.t()
  def chosen(tabs, param, default) do
    if Enum.any?(tabs, &(elem(&1, 0) == param)), do: param, else: default
  end

  defp normalize({id, label, icon}), do: {id, label, icon, nil}
  defp normalize({_id, _label, _icon, _count} = tab), do: tab
end
