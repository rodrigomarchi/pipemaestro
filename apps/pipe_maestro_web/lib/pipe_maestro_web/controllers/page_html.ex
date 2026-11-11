defmodule PipeMaestroWeb.PageHTML do
  @moduledoc "Templates rendered by `PipeMaestroWeb.PageController`."
  use PipeMaestroWeb, :html

  alias PipeMaestroWeb.LandingShots

  embed_templates "page_html/*"

  attr :shot, :map,
    required: true,
    doc: "a screenshot of `PipeMaestroWeb.LandingShots` (`all/0`, `walkthrough/0` or `docs/0`)"

  attr :loading, :string, default: "lazy", values: ~w(lazy eager)
  attr :class, :any, default: nil, doc: "classes for the frame"
  attr :rest, :global

  @doc """
  A screenshot of the platform inside a browser window: a bar with three dots
  and the address, then the light and the dark picture, of which the page's
  `dark` class shows one. A close-up (`kind: :detail`) is a part of the window,
  so it goes in a plain frame, without the bar.
  """
  @spec landing_shot(map()) :: Phoenix.LiveView.Rendered.t()
  def landing_shot(assigns) do
    assigns =
      assign(assigns,
        light: LandingShots.path(assigns.shot.name, :light),
        dark: LandingShots.path(assigns.shot.name, :dark)
      )

    ~H"""
    <figure
      class={[
        "overflow-hidden rounded-xl border border-gray-200 bg-white shadow-2xl shadow-primary-900/10 ring-1 ring-gray-900/5 dark:border-gray-700 dark:bg-gray-900 dark:shadow-black/40 dark:ring-white/10",
        @class
      ]}
      {@rest}
    >
      <div
        :if={@shot.kind != :detail}
        class="flex items-center gap-3 border-b border-gray-200 bg-gray-50 px-3 py-2 dark:border-gray-700 dark:bg-gray-800"
        aria-hidden="true"
      >
        <span class="flex gap-1.5">
          <span class="size-2.5 rounded-full bg-rose-400" />
          <span class="size-2.5 rounded-full bg-amber-400" />
          <span class="size-2.5 rounded-full bg-emerald-400" />
        </span>
        <span class="mx-auto truncate rounded-md bg-white px-3 py-0.5 font-mono text-[11px] text-gray-500 ring-1 ring-gray-200 dark:bg-gray-900 dark:text-gray-400 dark:ring-gray-700">
          app.pipemaestro.dev/w/nimbus
        </span>
        <span class="w-10" />
      </div>
      <img
        src={@light}
        alt={@shot.alt}
        width={@shot.width}
        height={@shot.height}
        loading={@loading}
        decoding="async"
        class="block h-auto w-full dark:hidden"
      />
      <img
        src={@dark}
        alt={@shot.alt}
        width={@shot.width}
        height={@shot.height}
        loading={@loading}
        decoding="async"
        class="hidden h-auto w-full dark:block"
      />
    </figure>
    """
  end

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
