defmodule PipeMaestroWeb.BoardLive.DecisionsTab do
  @moduledoc """
  The board's "Decisões" tab: every task of the workspace paused until
  someone decides, with the reason, and the way to the decisions page.
  The overview shows the first few through `decision_list/1`.
  """
  use PipeMaestroWeb, :html

  alias PipeMaestro.Tasks
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroWeb.Markdown
  import PipeMaestroWeb.TaskComponents, only: [stage_progress: 1]

  @doc "The tasks of `workspace` waiting for a decision."
  @spec load(Workspace.t()) :: [Tasks.Task.t()]
  def load(%Workspace{} = workspace), do: Tasks.list_awaiting(workspace)

  attr :awaiting, :list, required: true
  attr :slug, :string, required: true

  @doc "The tab."
  @spec decisions(map()) :: Phoenix.LiveView.Rendered.t()
  def decisions(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_header
        title="Decisões pendentes"
        description="Estas tarefas estão pausadas até alguém decidir."
      >
        <:action>
          <.button
            size="xs"
            variant="outline"
            color="gray"
            icon="hero-hand-raised"
            to={~p"/w/#{@slug}/decisions"}
            link_type="live_redirect"
            data-testid="board-decisions-link"
          >
            Decidir
          </.button>
        </:action>
      </.card_header>
      <.card_content>
        <.decision_list awaiting={@awaiting} slug={@slug} testid="board-decision" />
        <.empty
          :if={@awaiting == []}
          title="Nenhuma decisão pendente"
          description="Quando uma etapa pedir ajuda, esgotar as tentativas ou estourar o orçamento, a tarefa aparece aqui."
          data-testid="board-no-decisions"
        >
          <:icon><.icon name="hero-check-circle" /></:icon>
        </.empty>
      </.card_content>
    </.card>
    """
  end

  attr :awaiting, :list, required: true
  attr :slug, :string, required: true
  attr :testid, :string, required: true, doc: "each item's test id, before the task's id"

  @doc "The tasks waiting for a decision, each leading to the task."
  @spec decision_list(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_list(assigns) do
    ~H"""
    <div :if={@awaiting != []} class="divide-y divide-gray-200 dark:divide-gray-800">
      <.link
        :for={task <- @awaiting}
        navigate={~p"/w/#{@slug}/tasks/#{task.id}"}
        class="flex items-start gap-3 py-3 first:pt-0 last:pb-0"
        data-testid={"#{@testid}-#{task.id}"}
      >
        <span class="inline-flex size-8 shrink-0 items-center justify-center rounded-full bg-warning-100 text-warning-600 dark:bg-warning-500/15 dark:text-warning-400">
          <.icon name="hero-hand-raised" class="size-4" />
        </span>
        <span class="min-w-0">
          <span class="block text-sm font-semibold text-gray-900 dark:text-white">
            {task.title}
            <span class="font-normal text-gray-500 dark:text-gray-400">
              · {stage_progress(task)}
            </span>
          </span>
          <span class="block text-sm text-gray-600 dark:text-gray-400">
            {Markdown.inline_html(task.decision_reason)}
          </span>
        </span>
      </.link>
    </div>
    """
  end
end
