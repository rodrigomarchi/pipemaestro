defmodule PipeMaestroWeb.BrandComponents do
  @moduledoc """
  The PipeMaestro symbol, drawn inline.

  Three agents (the dots on the left) converge into one pipeline that runs
  through a stage and ends at the pull request (the solid dot on the right):
  the conductor of the pipeline, with no supplier's mark in it.

  The rounded square with the `primary` → `secondary` gradient is CSS on the
  `<svg>` itself and the strokes follow `currentColor`, so two symbols on one
  page share no element ids. The same drawing ships as static files in
  `priv/static/images/` (`logo-mark.svg`, `logo-mark-mono.svg` and the
  simplified `favicon.svg`).
  """
  use Phoenix.Component

  @doc """
  The symbol alone, in color: white strokes over the gradient square.

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
        "shrink-0 rounded-lg bg-gradient-to-br from-primary-500 to-secondary-500 text-white shadow-sm",
        @class
      ]}
      {@rest}
    >
      <title>PipeMaestro</title>
      <g stroke="currentColor" stroke-width="2.25" stroke-linecap="round">
        <path d="M7 9.5C11 9.5 12 16 16 16M7 22.5C11 22.5 12 16 16 16M7 16H21.5" />
      </g>
      <g fill="currentColor">
        <circle cx="7" cy="9.5" r="1.75" />
        <circle cx="7" cy="16" r="1.75" />
        <circle cx="7" cy="22.5" r="1.75" />
        <circle cx="25" cy="16" r="3" />
      </g>
      <circle cx="18.5" cy="16" r="1.6" fill="none" stroke="currentColor" stroke-width="1.5" />
    </svg>
    """
  end
end
