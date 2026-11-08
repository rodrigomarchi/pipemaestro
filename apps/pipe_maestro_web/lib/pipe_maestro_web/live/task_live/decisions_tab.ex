defmodule PipeMaestroWeb.TaskLive.DecisionsTab do
  @moduledoc """
  The task's "Decisões" tab: every decision taken in it, by whom, how, and
  with which answers and instructions.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.QuestionnaireComponents, only: [answer_list: 1]

  alias PipeMaestro.Tasks.Task
  alias PipeMaestroWeb.Markdown

  attr :task, Task, required: true
  attr :decisions, :list, required: true

  @doc "The tab."
  @spec decisions(map()) :: Phoenix.LiveView.Rendered.t()
  def decisions(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_header title="Decisões tomadas" />
      <.card_content>
        <p
          :if={@decisions == []}
          class="text-sm text-gray-500 dark:text-gray-400"
          data-testid="task-no-decisions"
        >
          Nenhuma decisão tomada nesta tarefa.
        </p>
        <ol :if={@decisions != []} class="space-y-3 text-sm" data-testid="task-decisions">
          <li :for={{decision, n} <- Enum.with_index(@decisions)} class="flex gap-3">
            <.icon name="hero-hand-raised" class="mt-0.5 size-4 shrink-0 text-warning-500" />
            <div class="min-w-0">
              <p class="text-gray-900 dark:text-white">
                <span class="font-medium">{decision_label(decision.action)}</span>
                em "{stage_name(@task, decision.stage_index)}"
                <span :if={decision.choice}>· escolha: {decision.choice}</span>
              </p>
              <.answer_list
                :if={decision.answers}
                answers={Map.merge(decision.questions || %{}, decision.answers)}
                class="my-1 space-y-1 text-sm"
                data-testid={"task-decision-answers-#{n}"}
              />
              <div
                :if={decision.instructions}
                class="prose prose-sm max-w-none text-gray-600 dark:prose-invert dark:text-gray-300"
              >
                {Markdown.to_html(decision.instructions)}
              </div>
              <p class="text-xs text-gray-500 dark:text-gray-400">
                {if decision.decided_by_user, do: decision.decided_by_user.name, else: "—"}
                <span :if={decision.decided_via} data-testid={"task-decision-via-#{n}"}>
                  (via {decision.decided_via})
                </span>
                · {Calendar.strftime(
                  decision.inserted_at,
                  "%d/%m %H:%M"
                )}
              </p>
            </div>
          </li>
        </ol>
      </.card_content>
    </.card>
    """
  end

  defp decision_label(:retry), do: "Refazer"
  defp decision_label(:advance), do: "Seguir"
  defp decision_label(:cancel), do: "Cancelar"
  defp decision_label(:correct), do: "Corrigir"

  defp stage_name(%Task{stages: stages}, index) do
    case Enum.at(stages, index) do
      nil -> "—"
      stage -> stage.name
    end
  end
end
