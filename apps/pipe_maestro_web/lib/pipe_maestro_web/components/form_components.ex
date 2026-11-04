defmodule PipeMaestroWeb.FormComponents do
  @moduledoc """
  The form pattern every screen follows (imported by `html_helpers/0`):

    * `icon_field/1`: a Petal `<.field>` whose label carries an icon, and
      `icon_label/1`, that label alone, for controls that are not a field
      (a combo box);
    * `markdown_editor/1`: a Markdown editor, with toolbar and preview, for
      every prompt or text the agent or a person reads as Markdown
      (`PipeMaestroWeb.MarkdownEditor`);
    * `section_heading/1` and `block_heading/1`: a form's sections (in a card)
      and the blocks inside them, each with its icon.
  """
  use Phoenix.Component
  use PetalComponents

  alias PipeMaestroWeb.MarkdownEditor

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :type, :string, default: "text"

  attr :hide_label, :boolean,
    default: false,
    doc: "a compact control: the icon beside it, no visible label"

  attr :rest, :global,
    include:
      ~w(id options rows placeholder help_text min max step no_margin class data-testid prompt autocomplete checked required viewable)

  @doc """
  A `<.field>` with an icon before its label. The visible label is decoration:
  the field keeps its own label (read by screen readers), so it is labelled
  once. A checkbox keeps Petal's label beside the box, after the icon; a
  `hide_label` field (a filter, an inline select) shows only the icon beside it.
  """
  @spec icon_field(map()) :: Phoenix.LiveView.Rendered.t()
  def icon_field(%{hide_label: true} = assigns) do
    ~H"""
    <div class="flex items-center gap-2" title={@label}>
      <.icon name={@icon} class="size-4 shrink-0 text-primary-500 dark:text-primary-400" />
      <div class="min-w-0 flex-1">
        <.field
          field={@field}
          type={@type}
          label={@label}
          label_class="sr-only"
          no_margin
          {@rest}
        />
      </div>
    </div>
    """
  end

  def icon_field(%{type: "checkbox"} = assigns) do
    ~H"""
    <div class="flex items-start gap-2">
      <.icon
        name={@icon}
        class="mt-0.5 size-4 shrink-0 text-primary-500 dark:text-primary-400"
      />
      <.field field={@field} type="checkbox" label={@label} {@rest} />
    </div>
    """
  end

  def icon_field(assigns) do
    ~H"""
    <div>
      <.icon_label icon={@icon} label={@label} />
      <.field field={@field} type={@type} label={@label} label_class="sr-only" {@rest} />
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true

  @doc """
  The visible label of a field, with its icon. Decoration: the control keeps
  its own accessible name (a `sr-only` label, an `aria-label`).
  """
  @spec icon_label(map()) :: Phoenix.LiveView.Rendered.t()
  def icon_label(assigns) do
    ~H"""
    <span aria-hidden="true" class="pc-label flex items-center gap-1.5">
      <.icon name={@icon} class="size-4 shrink-0 text-primary-500 dark:text-primary-400" />
      {@label}
    </span>
    """
  end

  attr :id, :string, required: true, doc: "unique on the page"
  attr :field, Phoenix.HTML.FormField, required: true

  attr :input_id, :string,
    default: nil,
    doc: "the textarea's id, when the field's repeats on the page"

  attr :label, :string, required: true
  attr :icon, :string, default: "hero-document-text"
  attr :testid, :string, required: true, doc: "the textarea's; the editor's parts derive from it"
  attr :variables, :list, default: [], doc: "the prompt variables the menu inserts"
  attr :rows, :integer, default: 8
  attr :placeholder, :string, default: nil
  attr :help_text, :string, default: nil

  @doc "A Markdown editor for `field`, with its toolbar and Write/Preview tabs."
  @spec markdown_editor(map()) :: Phoenix.LiveView.Rendered.t()
  def markdown_editor(assigns) do
    ~H"""
    <.live_component
      module={MarkdownEditor}
      id={@id}
      field={@field}
      input_id={@input_id || @field.id}
      label={@label}
      icon={@icon}
      testid={@testid}
      variables={@variables}
      rows={@rows}
      placeholder={@placeholder}
      help_text={@help_text}
    />
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil

  @doc "The heading of a form's section: an icon in a tile, a title and a line about it."
  @spec section_heading(map()) :: Phoenix.LiveView.Rendered.t()
  def section_heading(assigns) do
    ~H"""
    <div class="mb-5 flex gap-3">
      <span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary-50 text-primary-600 dark:bg-primary-950 dark:text-primary-300">
        <.icon name={@icon} class="size-5" />
      </span>
      <div>
        <h2 class="font-semibold text-gray-900 dark:text-white">{@title}</h2>
        <p :if={@description} class="text-sm text-gray-500 dark:text-gray-400">{@description}</p>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true

  @doc "The heading of a block of fields inside a section."
  @spec block_heading(map()) :: Phoenix.LiveView.Rendered.t()
  def block_heading(assigns) do
    ~H"""
    <h4 class="mb-3 flex items-center gap-2 text-sm font-medium text-gray-900 dark:text-white">
      <.icon name={@icon} class="size-4 text-primary-500 dark:text-primary-400" />
      {@title}
    </h4>
    """
  end
end
