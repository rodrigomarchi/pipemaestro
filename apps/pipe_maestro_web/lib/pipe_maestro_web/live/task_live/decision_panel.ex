defmodule PipeMaestroWeb.TaskLive.DecisionPanel do
  @moduledoc """
  The decision a task waits for, at the top of the waiting stage's panel: the
  reason, the analysis of a failure while it runs, the questionnaire of the
  pause (`PipeMaestroWeb.QuestionnaireLive`), if any, and the manual decision
  (the agent's options, Refazer, Seguir, "Sugerir com IA"), folded away while
  there is something to answer.

  Its events (`decide`, `questionnaire`, `suggest_decision`, `cancel`) carry
  no target: they go to the task's LiveView, which decides.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.QuestionnaireComponents, only: [analysis_state: 1]

  alias PipeMaestro.Tasks.Task
  alias PipeMaestroWeb.{Markdown, QuestionnaireLive}

  attr :task, Task, required: true
  attr :questionnaire, :map, required: true, doc: "`PipeMaestro.Tasks.questionnaire/1`"
  attr :options, :list, required: true, doc: "the options the agent proposed"
  attr :form, Phoenix.HTML.Form, required: true
  attr :can_cancel, :boolean, required: true

  @doc "The decision panel."
  @spec decision_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_panel(assigns) do
    ~H"""
    <.card
      variant="outline"
      class="border-warning-300 dark:border-warning-800"
      data-testid="decision-panel"
    >
      <.card_content>
        <.alert color="warning" with_icon data-testid="decision-reason">
          {Markdown.inline_html(@task.decision_reason)}
        </.alert>
        <.analysis_state analysis={@questionnaire.analysis} />
        <.live_component
          :if={@questionnaire.questionnaire}
          module={QuestionnaireLive}
          id={"questionnaire-#{@task.id}"}
          task_id={@task.id}
          questionnaire={@questionnaire.questionnaire}
          can_cancel={@can_cancel}
        />
        <details
          class="group mt-4 rounded-lg border border-gray-200 p-3 dark:border-gray-700"
          open={is_nil(@questionnaire.questionnaire) and @questionnaire.analysis != :running}
          id="decision-manual"
          phx-mounted={JS.ignore_attributes(["open"])}
          data-testid="decision-manual"
        >
          <summary
            class="cursor-pointer text-sm font-medium text-gray-700 dark:text-gray-200"
            data-testid="decision-manual-toggle"
          >
            Decidir sem responder
          </summary>
          <div class="mt-3 flex justify-end">
            <.button
              type="button"
              size="sm"
              variant="outline"
              icon="hero-cpu-chip"
              phx-click="suggest_decision"
              data-testid="decision-suggest"
            >
              Sugerir com IA
            </.button>
          </div>
          <.form for={@form} id="decision-form" phx-submit="decide" class="mt-4">
            <.markdown_editor
              id="decision-instructions"
              field={@form[:instructions]}
              label="Instruções para continuar (opcional)"
              icon="hero-chat-bubble-left-right"
              rows={3}
              placeholder="Ex.: o problema acontece no Safari; ignore o módulo legado."
              testid="decision-instructions"
            />
            <div :if={@options != []} class="mb-3">
              <p class="mb-2 text-sm text-gray-600 dark:text-gray-300">
                O agente propôs (refaz a etapa com a escolha e as instruções):
              </p>
              <div class="flex flex-wrap gap-2">
                <.button
                  :for={{option, index} <- Enum.with_index(@options)}
                  type="submit"
                  name="choice"
                  value={option}
                  size="sm"
                  variant="outline"
                  color="primary"
                  data-testid={"decision-option-#{index}"}
                >
                  {option}
                </.button>
              </div>
            </div>
            <div class="flex flex-wrap justify-end gap-2">
              <.button
                type="submit"
                name="action"
                value="retry"
                variant="outline"
                icon="hero-arrow-path"
                data-testid="decision-retry"
              >
                Refazer etapa
              </.button>
              <.button
                type="submit"
                name="action"
                value="advance"
                icon="hero-forward"
                data-testid="decision-advance"
              >
                Seguir para a próxima
              </.button>
            </div>
          </.form>
        </details>
      </.card_content>
    </.card>
    """
  end
end
