defmodule PipeMaestroWeb.PageHTML do
  @moduledoc "Templates rendered by `PipeMaestroWeb.PageController`."
  use PipeMaestroWeb, :html

  embed_templates "page_html/*"

  attr :label, :string, required: true

  @doc "The labelled two-way arrow between two boxes of a landing diagram."
  @spec diagram_link(map()) :: Phoenix.LiveView.Rendered.t()
  def diagram_link(assigns) do
    ~H"""
    <div class="flex flex-row items-center justify-center gap-2 text-primary-500 lg:flex-col dark:text-primary-400">
      <.icon name="hero-arrows-right-left" class="size-6 rotate-90 lg:rotate-0" />
      <span class="text-xs font-medium whitespace-nowrap">{@label}</span>
    </div>
    """
  end
end
