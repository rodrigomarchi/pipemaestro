defmodule PipeMaestroWeb.QuestionnaireLive do
  @moduledoc """
  The questionnaire of a task's pause, for a person to answer: each question's
  options as selectable cards (one, or several when the question takes
  several), "Outro" with free text always offered, the progress, and a review
  step before sending.

  It keeps the answers in progress while the questionnaire stays the same.
  What the person chose goes straight to the LiveView it lives in, so the
  decision is taken while the click is handled: the event `"questionnaire"`
  with `task_id`, `action` (`"answer"`, to answer and run the stage again;
  `"advance"`, to go on, answered or not; `"cancel"`) and `answers` (JSON,
  one per question). The LiveView decides through `PipeMaestro.Tasks`, which
  validates the answers.

  Assigns: `id`, `task_id`, `questionnaire`, `key` (the test ids' suffix on a
  page with several) and `can_cancel`.
  """
  use PipeMaestroWeb, :live_component

  import PipeMaestroWeb.QuestionnaireComponents

  alias PipeMaestro.Tasks.Questionnaire

  @impl true
  def mount(socket), do: {:ok, assign(socket, answers: %{}, review: false)}

  @impl true
  def update(assigns, socket) do
    same? = socket.assigns[:questionnaire] == assigns.questionnaire

    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:key, fn -> nil end)
     |> assign_new(:can_cancel, fn -> false end)
     |> then(&if(same?, do: &1, else: assign(&1, answers: %{}, review: false)))}
  end

  @impl true
  def handle_event("change", %{"answers" => params}, socket) when is_map(params) do
    answers =
      Enum.reduce(params, socket.assigns.answers, fn {index, answer}, acc ->
        case Integer.parse(index) do
          {n, ""} when is_map(answer) ->
            Map.put(acc, n, %{
              "escolhas" => Questionnaire.choices(answer),
              "outro" => answer["outro"]
            })

          _other ->
            acc
        end
      end)

    {:noreply, assign(socket, answers: answers)}
  end

  def handle_event("change", _params, socket), do: {:noreply, socket}

  def handle_event("submit", params, socket) do
    {:noreply, socket} = handle_event("change", params, socket)
    {:noreply, assign(socket, review: complete?(socket.assigns))}
  end

  def handle_event("back", _params, socket), do: {:noreply, assign(socket, review: false)}

  defp questions(assigns), do: assigns.questionnaire["perguntas"] || []

  defp current_answers(assigns) do
    for n <- 0..(length(questions(assigns)) - 1)//1 do
      answer = Map.get(assigns.answers, n, %{})
      %{"escolhas" => Questionnaire.choices(answer), "outro" => Questionnaire.other(answer)}
    end
  end

  defp answered(assigns),
    do: Enum.count(current_answers(assigns), &Questionnaire.answered?/1)

  defp complete?(assigns), do: answered(assigns) == length(questions(assigns))

  defp chosen?(answers, n, label), do: label in Questionnaire.choices(Map.get(answers, n))

  defp other_text(answers, n), do: (Map.get(answers, n) || %{})["outro"] || ""

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        total: length(questions(assigns)),
        done: answered(assigns),
        complete: complete?(assigns),
        list: current_answers(assigns)
      )

    ~H"""
    <div class="mt-4 space-y-3" data-testid={testid("questionnaire", @key)}>
      <.diagnosis questionnaire={@questionnaire} key={@key} />

      <div
        class="flex flex-wrap items-center gap-3"
        data-testid={testid("questionnaire-progress", @key)}
      >
        <.badge color={if @complete, do: "success", else: "gray"} size="sm">
          {@done} de {@total} respondidas
        </.badge>
        <.progress
          value={@done}
          max={max(@total, 1)}
          size="sm"
          color="primary"
          class="min-w-24 flex-1"
        />
      </div>

      <div
        :if={@review}
        class="space-y-3 rounded-lg border border-primary-200 p-4 dark:border-primary-800"
        data-testid={testid("questionnaire-review", @key)}
      >
        <p class="text-sm font-medium text-gray-900 dark:text-white">Confira as respostas</p>
        <.answer_list answers={%{"perguntas" => questions(assigns), "respostas" => @list}} />
        <div class="flex flex-wrap justify-end gap-2">
          <.button
            type="button"
            variant="outline"
            icon="hero-arrow-uturn-left"
            phx-click="back"
            phx-target={@myself}
            class="w-full sm:w-auto"
            data-testid={testid("questionnaire-back", @key)}
          >
            Voltar
          </.button>
          <.button
            type="button"
            icon="hero-paper-airplane"
            phx-click="questionnaire"
            phx-value-action="answer"
            phx-value-task_id={@task_id}
            phx-value-answers={Jason.encode!(@list)}
            class="w-full sm:w-auto"
            data-testid={testid("questionnaire-confirm", @key)}
          >
            Confirmar
          </.button>
        </div>
      </div>

      <form
        :if={not @review}
        id={testid("questionnaire-form", @key)}
        phx-change="change"
        phx-submit="submit"
        phx-target={@myself}
        class="space-y-3"
        data-testid={testid("questionnaire-form", @key)}
      >
        <.card
          :for={{question, n} <- Enum.with_index(@questionnaire["perguntas"] || [])}
          variant="outline"
          data-testid={testid("question-#{n}", @key)}
        >
          <.card_content>
            <.question_heading question={question} />
            <input type="hidden" name={"answers[#{n}][escolhas][]"} value="" />
            <div class="mt-3 grid gap-2 sm:grid-cols-2">
              <div
                :for={{option, m} <- Enum.with_index(question["opcoes"])}
                data-testid={testid("question-#{n}-option-#{m}", @key)}
              >
                <label class={[
                  "block cursor-pointer rounded-lg border border-gray-200 p-3 dark:border-gray-700",
                  "hover:border-primary-300 dark:hover:border-primary-700",
                  "has-[:checked]:border-primary-500 has-[:checked]:bg-primary-50",
                  "dark:has-[:checked]:border-primary-400 dark:has-[:checked]:bg-primary-950/40"
                ]}>
                  <input
                    type={if question["multipla"], do: "checkbox", else: "radio"}
                    name={"answers[#{n}][escolhas][]"}
                    value={option["rotulo"]}
                    checked={chosen?(@answers, n, option["rotulo"])}
                    class="sr-only"
                  />
                  <.option_text option={option} />
                </label>
                <.option_preview
                  option={option}
                  id={testid("question-#{n}-preview-#{m}", @key)}
                />
              </div>
            </div>
            <div
              class="mt-2 rounded-lg border border-dashed border-gray-300 p-3 dark:border-gray-600"
              data-testid={testid("question-#{n}-other", @key)}
            >
              <label class="text-sm font-medium text-gray-900 dark:text-white">
                Outro
                <.input
                  type="text"
                  id={testid("question-#{n}-other-input", @key)}
                  name={"answers[#{n}][outro]"}
                  value={other_text(@answers, n)}
                  placeholder="Responda com suas palavras"
                  class="mt-1"
                  phx-debounce="300"
                  data-testid={testid("question-#{n}-other-text", @key)}
                />
              </label>
            </div>
          </.card_content>
        </.card>

        <div class="flex flex-wrap justify-end gap-2">
          <.button
            :if={@can_cancel}
            type="button"
            variant="ghost"
            color="danger"
            icon="hero-x-mark"
            phx-click="questionnaire"
            phx-value-action="cancel"
            phx-value-task_id={@task_id}
            phx-value-answers={Jason.encode!(@list)}
            data-confirm="Cancelar a tarefa?"
            class="w-full sm:w-auto"
            data-testid={testid("questionnaire-cancel", @key)}
          >
            Cancelar a tarefa
          </.button>
          <.button
            type="button"
            variant="outline"
            icon="hero-forward"
            phx-click="questionnaire"
            phx-value-action="advance"
            phx-value-task_id={@task_id}
            phx-value-answers={Jason.encode!(@list)}
            class="w-full sm:w-auto"
            data-testid={testid("questionnaire-advance", @key)}
          >
            Avançar mesmo assim
          </.button>
          <.button
            type="submit"
            icon="hero-paper-airplane"
            disabled={not @complete}
            class="w-full sm:w-auto"
            data-testid={testid("questionnaire-submit", @key)}
          >
            Responder e continuar
          </.button>
        </div>
      </form>
    </div>
    """
  end
end
