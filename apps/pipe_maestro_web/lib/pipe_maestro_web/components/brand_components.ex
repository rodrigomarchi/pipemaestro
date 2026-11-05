defmodule PipeMaestroWeb.BrandComponents do
  @moduledoc """
  The PipeMaestro symbol, drawn inline.

  Three agents (the pads on the left) converge into one pipeline that runs
  through a stage (the ring) and ends at the pull request (the solid dot on the
  right): the conductor of the pipeline, with no supplier's mark in it.

  The look is a circuit board in neon: violet traces with 45° corners and
  hollow pads, a cyan ring and dot, all on a dark square. The square, its ring
  and outer glow are CSS on the `<svg>` itself, and the neon halo is a wider,
  translucent copy of each stroke under it, so two symbols on one page share no
  element ids, definitions or filters. The same drawing ships as static files in
  `priv/static/images/` (`logo-mark.svg`, `logo-mark-mono.svg` and the
  simplified `favicon.svg`).
  """
  use Phoenix.Component

  @doc """
  The symbol alone, in color: neon traces over the dark square.

  Size it through `class` (e.g. `size-8`); extra attributes go to the `<svg>`.
  """
  attr :class, :any, default: nil
  attr :rest, :global

  @spec logo_mark(map()) :: Phoenix.LiveView.Rendered.t()
  def logo_mark(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 32 32"
      role="img"
      fill="none"
      class={[
        "shrink-0 rounded-lg bg-gradient-to-br from-primary-950 to-secondary-950",
        "ring-1 ring-primary-400/30 shadow-md shadow-primary-500/40",
        @class
      ]}
      {@rest}
    >
      <title>PipeMaestro</title>
      <g
        class="stroke-primary-400"
        stroke-width="4"
        stroke-opacity="0.3"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M9 9H11L18 16M9 23H11L18 16M9 16H19.6" />
        <circle cx="7" cy="9" r="2" />
        <circle cx="7" cy="16" r="2" />
        <circle cx="7" cy="23" r="2" />
      </g>
      <g class="stroke-secondary-400" stroke-width="3.5" stroke-opacity="0.3">
        <path d="M23.4 16H23.75" />
        <circle cx="21.5" cy="16" r="1.9" />
        <circle cx="26.5" cy="16" r="3.75" />
      </g>
      <g stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">
        <path class="stroke-primary-400" d="M9 9H11L18 16M9 23H11L18 16M9 16H19.6" />
        <circle class="stroke-primary-400" cx="7" cy="9" r="2" />
        <circle class="stroke-primary-400" cx="7" cy="16" r="2" />
        <circle class="stroke-primary-400" cx="7" cy="23" r="2" />
        <path class="stroke-secondary-400" d="M23.4 16H23.75" />
        <circle class="stroke-secondary-400" cx="21.5" cy="16" r="1.9" stroke-width="1.5" />
      </g>
      <circle class="fill-secondary-400" cx="26.5" cy="16" r="2.75" />
    </svg>
    """
  end
end
