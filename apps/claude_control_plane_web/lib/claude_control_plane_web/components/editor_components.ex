defmodule ClaudeControlPlaneWeb.EditorComponents do
  @moduledoc """
  A Markdown editor over a form's textarea: a toolbar that formats the
  selection and inserts prompt variables (the `MarkdownEditor` hook in
  `assets/js/markdown_editor.js`), and Write/Preview tabs, the preview rendered
  on the server (`ClaudeControlPlaneWeb.Markdown`).

  `icon_field/1` is a form field whose label carries an icon.

  The editor's textarea stays the real input, also while the preview shows, so the form
  keeps its value and tests fill it as any other field. The LiveView owns which
  editors show their preview: the tabs send `toggle_preview` with the editor's
  `id`.
  """
  use Phoenix.Component
  use PetalComponents

  alias ClaudeControlPlaneWeb.Markdown

  @formats [
    {"bold", "hero-bold", "Negrito (⌘B)"},
    {"italic", "hero-italic", "Itálico (⌘I)"},
    {"heading", "hero-h2", "Título"},
    {"bullet", "hero-list-bullet", "Lista"},
    {"numbered", "hero-numbered-list", "Lista numerada"},
    {"quote", "hero-chat-bubble-bottom-center-text", "Citação"},
    {"code", "hero-code-bracket", "Código"},
    {"link", "hero-link", "Link (⌘K)"}
  ]

  attr :id, :string, required: true, doc: "unique on the page; also what `toggle_preview` gets"
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: "hero-document-text"
  attr :testid, :string, required: true, doc: "the textarea's; the editor's parts derive from it"
  attr :preview, :boolean, default: false
  attr :variables, :list, default: [], doc: "the prompt variables the menu inserts"
  attr :rows, :integer, default: 8
  attr :placeholder, :string, default: nil
  attr :help_text, :string, default: nil

  @doc "A Markdown editor for `field`, with its toolbar and Write/Preview tabs."
  @spec markdown_editor(map()) :: Phoenix.LiveView.Rendered.t()
  def markdown_editor(assigns) do
    assigns = assign(assigns, :formats, @formats)

    ~H"""
    <div id={@id} phx-hook="MarkdownEditor" data-testid={"#{@testid}-editor"}>
      <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
        <span class="flex items-center gap-2 text-sm font-medium text-gray-900 dark:text-white">
          <.icon name={@icon} class="size-4 text-primary-500 dark:text-primary-400" />
          {@label}
        </span>
        <div class="inline-flex rounded-lg bg-gray-100 p-0.5 text-xs dark:bg-gray-800">
          <button
            :for={
              {preview, icon, text} <- [
                {false, "hero-pencil-square", "Escrever"},
                {true, "hero-eye", "Visualizar"}
              ]
            }
            type="button"
            phx-click="toggle_preview"
            phx-value-id={@id}
            phx-value-preview={to_string(preview)}
            aria-pressed={to_string(preview == @preview)}
            class={[
              "inline-flex items-center gap-1 rounded-md px-2.5 py-1 font-medium transition",
              if(preview == @preview,
                do: "bg-white text-gray-900 shadow-sm dark:bg-gray-700 dark:text-white",
                else: "text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-white"
              )
            ]}
            data-testid={"#{@testid}-#{if preview, do: "preview", else: "write"}-tab"}
          >
            <.icon name={icon} class="size-3.5" />
            {text}
          </button>
        </div>
      </div>

      <div class={@preview && "hidden"}>
        <div
          role="toolbar"
          aria-label={"Formatar #{@label}"}
          class="mb-1.5 flex flex-wrap items-center gap-0.5"
        >
          <button
            :for={{action, icon, title} <- @formats}
            type="button"
            data-md-action={action}
            title={title}
            aria-label={title}
            class="rounded-md p-1.5 text-gray-500 transition hover:bg-gray-100 hover:text-gray-900 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-white"
            data-testid={"#{@testid}-#{action}"}
          >
            <.icon name={icon} class="size-4" />
          </button>
          <details :if={@variables != []} class="group ml-1">
            <summary
              class="flex cursor-pointer list-none items-center gap-1 rounded-md px-2 py-1 text-xs font-medium text-primary-700 hover:bg-primary-50 dark:text-primary-300 dark:hover:bg-primary-950"
              data-testid={"#{@testid}-variables"}
            >
              <.icon name="hero-variable" class="size-4" /> Variável
              <.icon name="hero-chevron-down" class="size-3 transition group-open:rotate-180" />
            </summary>
            <div class="mt-1.5 flex flex-wrap gap-1.5">
              <button
                :for={variable <- @variables}
                type="button"
                data-md-insert={"{{#{variable}}}"}
                class="rounded-md bg-primary-50 px-2 py-0.5 font-mono text-xs text-primary-700 transition hover:bg-primary-100 dark:bg-primary-950 dark:text-primary-300 dark:hover:bg-primary-900"
                data-testid={"#{@testid}-variable-#{variable}"}
              >
                {"{{#{variable}}}"}
              </button>
            </div>
          </details>
        </div>
        <.field
          field={@field}
          type="textarea"
          rows={@rows}
          label={@label}
          label_class="sr-only"
          placeholder={@placeholder}
          help_text={@help_text}
          class="font-mono text-sm leading-relaxed"
          data-testid={@testid}
        />
      </div>

      <div
        :if={@preview}
        id={"#{@id}-preview"}
        phx-hook="Highlight"
        class="prose prose-sm max-w-none rounded-lg border border-gray-200 bg-gray-50 px-4 py-3 prose-h1:text-xl prose-h2:text-lg prose-h3:text-base dark:prose-invert dark:border-gray-700 dark:bg-gray-950"
        data-testid={"#{@testid}-preview"}
      >
        <%= if blank?(@field.value) do %>
          <p class="text-gray-400 dark:text-gray-500">Nada para visualizar ainda.</p>
        <% else %>
          {Markdown.to_html(@field.value)}
        <% end %>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :type, :string, default: "text"

  attr :rest, :global,
    include:
      ~w(options rows placeholder help_text min max step no_margin class data-testid prompt)

  @doc """
  A `<.field>` with an icon before its label. The visible label is decoration:
  the field keeps its own label (read by screen readers), so it is labelled
  once.
  """
  @spec icon_field(map()) :: Phoenix.LiveView.Rendered.t()
  def icon_field(assigns) do
    ~H"""
    <div>
      <span aria-hidden="true" class="pc-label flex items-center gap-1.5">
        <.icon name={@icon} class="size-4 shrink-0 text-primary-500 dark:text-primary-400" />
        {@label}
      </span>
      <.field field={@field} type={@type} label={@label} label_class="sr-only" {@rest} />
    </div>
    """
  end

  defp blank?(value), do: value in [nil, ""] or String.trim(to_string(value)) == ""
end
