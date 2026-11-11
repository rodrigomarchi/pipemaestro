defmodule PipeMaestroWeb.DocsHTML do
  @moduledoc "Templates rendered by `PipeMaestroWeb.DocsController`."
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.PageHTML, only: [landing_shot: 1]

  embed_templates "docs_html/*"

  attr :sections, :list, required: true, doc: "`PipeMaestroWeb.Docs.sections/0`"
  attr :current, :string, required: true, doc: "the slug of the page being read"
  attr :prefix, :string, required: true, doc: "the test id prefix of this copy of the index"

  @doc """
  The index of every page, by section, with the page being read marked. The
  page renders it twice (a sticky column on a wide screen, a collapsible
  menu on a phone), each copy with its own test id prefix.
  """
  @spec docs_index(map()) :: Phoenix.LiveView.Rendered.t()
  def docs_index(assigns) do
    ~H"""
    <div class="space-y-6">
      <div :for={section <- @sections}>
        <p
          id={"#{@prefix}-section-#{section.key}"}
          class="flex items-center gap-2 text-xs font-semibold tracking-wide text-gray-500 uppercase dark:text-gray-400"
        >
          <.icon name={section.icon} class="size-4 text-primary-500" aria-hidden="true" />
          {section.title}
        </p>
        <ul
          class="mt-2 space-y-0.5 border-l border-gray-200 dark:border-gray-800"
          aria-labelledby={"#{@prefix}-section-#{section.key}"}
        >
          <li :for={page <- section.pages}>
            <.link
              href={~p"/docs/#{page.slug}"}
              data-testid={"#{@prefix}-#{page.slug}"}
              aria-current={if page.slug == @current, do: "page"}
              class={[
                "-ml-px block border-l py-1.5 pl-4 text-sm",
                if(page.slug == @current,
                  do: "border-primary-500 font-medium text-primary-700 dark:text-primary-300",
                  else:
                    "border-transparent text-gray-600 hover:border-gray-400 hover:text-gray-900 dark:text-gray-400 dark:hover:text-white"
                )
              ]}
            >
              {page.title}
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :page, :map, required: true
  attr :direction, :atom, required: true, values: [:previous, :next]

  @doc "The link to the page before or after the one being read."
  @spec neighbor_link(map()) :: Phoenix.LiveView.Rendered.t()
  def neighbor_link(assigns) do
    ~H"""
    <.link
      href={~p"/docs/#{@page.slug}"}
      data-testid={"docs-#{@direction}"}
      class={[
        "group flex flex-col rounded-xl border border-gray-200 p-4 hover:border-primary-400 dark:border-gray-800 dark:hover:border-primary-600",
        @direction == :next && "text-right sm:col-start-2"
      ]}
    >
      <span class="text-xs text-gray-500 dark:text-gray-400">
        {if @direction == :next, do: "Próxima", else: "Anterior"}
      </span>
      <span class="mt-1 font-medium text-gray-900 group-hover:text-primary-700 dark:text-white dark:group-hover:text-primary-300">
        {@page.title}
      </span>
    </.link>
    """
  end
end
