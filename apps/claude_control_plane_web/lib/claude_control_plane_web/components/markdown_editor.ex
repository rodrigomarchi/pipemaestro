defmodule ClaudeControlPlaneWeb.MarkdownEditor do
  @moduledoc """
  A Markdown editor over a form's textarea (`ClaudeControlPlaneWeb.FormComponents.markdown_editor/1`
  renders it): a toolbar that formats the selection and inserts prompt
  variables (the `MarkdownEditor` hook in `assets/js/markdown_editor.js`), and
  Write/Preview tabs, the preview rendered on the server
  (`ClaudeControlPlaneWeb.Markdown`).

  The editor keeps which tab shows. The textarea stays the real input, also
  while the preview shows, so the parent form keeps its value, validates it as
  it is typed, and tests fill it as any other field.
  """
  use Phoenix.LiveComponent
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

  @impl true
  def mount(socket), do: {:ok, assign(socket, preview: false, text: nil, formats: @formats)}

  # The hook sends the textarea's text with the click, so the preview shows what
  # is typed also in a form that does not track its fields as they change.
  @impl true
  def handle_event("toggle_preview", %{"preview" => preview} = params, socket),
    do: {:noreply, assign(socket, preview: preview == "true", text: params["text"])}

  @impl true
  def render(assigns) do
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
            phx-target={@myself}
            phx-value-preview={to_string(preview)}
            data-md-preview={preview && "true"}
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
          id={@input_id}
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
        <%= if blank?(@text || @field.value) do %>
          <p class="text-gray-400 dark:text-gray-500">Nada para visualizar ainda.</p>
        <% else %>
          {Markdown.to_html(@text || @field.value)}
        <% end %>
      </div>
    </div>
    """
  end

  defp blank?(value), do: value in [nil, ""] or String.trim(to_string(value)) == ""
end
