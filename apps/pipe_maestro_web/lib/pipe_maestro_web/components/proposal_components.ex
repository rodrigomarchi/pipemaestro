defmodule PipeMaestroWeb.ProposalComponents do
  @moduledoc """
  The review of each kind of proposal (`PipeMaestro.Proposals`), shown once
  the agent has answered. Their forms' events are the proposal page's
  (`PipeMaestroWeb.ProposalLive.Show`).
  """
  use PipeMaestroWeb, :html

  alias PipeMaestro.Proposals
  alias PipeMaestroWeb.Markdown

  @doc "A proposal's kind as a badge, with its icon."
  attr :kind, :string, required: true
  attr :rest, :global

  @spec kind_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def kind_badge(assigns) do
    module = Proposals.kind_module(assigns.kind)
    assigns = assign(assigns, label: module.label(), icon: module.icon())

    ~H"""
    <span
      class="inline-flex items-center gap-1 rounded-full bg-primary-50 px-2 py-0.5 text-xs font-medium text-primary-700 dark:bg-primary-950 dark:text-primary-300"
      {@rest}
    >
      <.icon name={@icon} class="size-3.5" /> {@label}
    </span>
    """
  end

  @doc "Markdown the agent wrote, in a card with a heading."
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :markdown, :string, required: true
  attr :testid, :string, required: true

  @spec markdown_card(map()) :: Phoenix.LiveView.Rendered.t()
  def markdown_card(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_content>
        <.section_heading icon={@icon} title={@title} />
        <div
          id={@id}
          phx-hook="Highlight"
          class="prose prose-sm max-w-none dark:prose-invert"
          data-testid={@testid}
        >
          {Markdown.to_html(@markdown)}
        </div>
      </.card_content>
    </.card>
    """
  end

  @doc "The commands the agent ran to check what it proposes."
  attr :checks, :list, required: true

  @spec checks(map()) :: Phoenix.LiveView.Rendered.t()
  def checks(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_content>
        <.section_heading
          icon="hero-command-line"
          title="Verificações"
          description="Comandos que o agente rodou no worktree descartável."
        />
        <p
          :if={@checks == []}
          class="text-sm text-gray-500 dark:text-gray-400"
          data-testid="proposal-no-checks"
        >
          O agente não registrou verificações.
        </p>
        <ul class="space-y-2" data-testid="proposal-checks">
          <li :for={check <- @checks} class="flex items-start gap-2 text-sm">
            <.icon
              name={if check.passed, do: "hero-check-circle", else: "hero-x-circle"}
              class={[
                "mt-0.5 size-5 shrink-0",
                if(check.passed, do: "text-success-500", else: "text-danger-500")
              ]}
            />
            <div class="min-w-0">
              <code class="break-all text-xs text-gray-800 dark:text-gray-100">
                {check.command}
              </code>
              <p :if={check.note != ""} class="text-xs text-gray-500 dark:text-gray-400">
                {check.note}
              </p>
            </div>
          </li>
        </ul>
      </.card_content>
    </.card>
    """
  end

  @doc "What a decision does, as a label."
  @spec action_label(String.t()) :: String.t()
  def action_label("retry"), do: "Tentar de novo"
  def action_label("advance"), do: "Avançar"
  def action_label("cancel"), do: "Cancelar a tarefa"

  @doc "The icon of a decision's action."
  @spec action_icon(String.t()) :: String.t()
  def action_icon("retry"), do: "hero-arrow-path"
  def action_icon("advance"), do: "hero-forward"
  def action_icon("cancel"), do: "hero-x-circle"
end
