defmodule PipeMaestroWeb.QuestionnaireComponents do
  @moduledoc """
  The questionnaire of a task's pause (`PipeMaestro.Tasks.Questionnaire`),
  read-only: the diagnosis, each question with its options (the recommended
  one marked, a preview to open) and, when given, what the person answered.
  The questionnaire a person answers is `PipeMaestroWeb.QuestionnaireLive`,
  built from the same pieces.

  On a page with several questionnaires, `key` suffixes every test id
  (`questionnaire-<key>`, `question-0-<key>`).
  """
  use PipeMaestroWeb, :html

  alias PipeMaestro.Tasks.Questionnaire
  alias PipeMaestroWeb.Markdown

  @doc """
  The answers the questionnaire's buttons send (`phx-value-answers`, JSON),
  or `nil` when they are not a list: `PipeMaestro.Tasks` then refuses them.
  """
  @spec decode_answers(String.t() | nil) :: list() | nil
  def decode_answers(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, answers} when is_list(answers) -> answers
      _invalid -> nil
    end
  end

  def decode_answers(_none), do: nil

  @doc "A test id, suffixed with `key` when there is one."
  @spec testid(String.t(), String.t() | nil) :: String.t()
  def testid(base, nil), do: base
  def testid(base, key), do: base <> "-" <> key

  attr :questionnaire, :map, required: true
  attr :answers, :list, default: nil, doc: "what the person answered, one per question"
  attr :key, :string, default: nil

  @doc "A questionnaire, read-only, with the answers when given."
  @spec questionnaire(map()) :: Phoenix.LiveView.Rendered.t()
  def questionnaire(assigns) do
    ~H"""
    <div class="space-y-3" data-testid={testid("questionnaire", @key)}>
      <.diagnosis questionnaire={@questionnaire} key={@key} />
      <.card
        :for={{question, n} <- Enum.with_index(@questionnaire["perguntas"] || [])}
        variant="outline"
        data-testid={testid("question-#{n}", @key)}
      >
        <.card_content>
          <.question_heading question={question} />
          <ul class="mt-3 grid gap-2 sm:grid-cols-2">
            <li
              :for={{option, m} <- Enum.with_index(question["opcoes"])}
              class="rounded-lg border border-gray-200 p-3 dark:border-gray-700"
              data-testid={testid("question-#{n}-option-#{m}", @key)}
            >
              <.option_text option={option} />
              <.option_preview option={option} id={testid("question-#{n}-preview-#{m}", @key)} />
            </li>
          </ul>
          <p :if={@answers} class="mt-3 text-sm text-gray-900 dark:text-white">
            <span class="font-medium">Resposta:</span>
            {Questionnaire.answer_text(Enum.at(@answers, n))}
          </p>
        </.card_content>
      </.card>
    </div>
    """
  end

  attr :questionnaire, :map, required: true
  attr :key, :string, default: nil

  @doc "The analysis' diagnosis, as Markdown, when the questionnaire has one."
  @spec diagnosis(map()) :: Phoenix.LiveView.Rendered.t()
  def diagnosis(assigns) do
    ~H"""
    <.alert
      :if={@questionnaire["diagnostico"] not in [nil, ""]}
      color="info"
      with_icon
      heading="Diagnóstico do agente"
      data-testid={testid("questionnaire-diagnosis", @key)}
    >
      <div class="prose prose-sm max-w-none dark:prose-invert">
        {Markdown.to_html(@questionnaire["diagnostico"])}
      </div>
    </.alert>
    """
  end

  attr :question, :map, required: true

  @doc "A question's tag (with its stage, in a group) and the question itself."
  @spec question_heading(map()) :: Phoenix.LiveView.Rendered.t()
  def question_heading(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <.badge color="primary" size="sm">
        {if @question["etapa"], do: "#{@question["etapa"]} · "}{@question["titulo"]}
      </.badge>
      <.badge :if={@question["multipla"]} color="gray" size="sm">várias respostas</.badge>
    </div>
    <p class="mt-2 font-medium text-gray-900 dark:text-white">{@question["pergunta"]}</p>
    """
  end

  attr :option, :map, required: true

  @doc "An option's label, recommended mark and description."
  @spec option_text(map()) :: Phoenix.LiveView.Rendered.t()
  def option_text(assigns) do
    ~H"""
    <span class="flex flex-wrap items-center gap-2">
      <span class="font-medium text-gray-900 dark:text-white">{@option["rotulo"]}</span>
      <.badge :if={@option["recomendada"]} color="success" size="sm">recomendada</.badge>
    </span>
    <span
      :if={@option["descricao"] not in [nil, ""]}
      class="mt-1 block text-sm text-gray-600 dark:text-gray-300"
    >
      {@option["descricao"]}
    </span>
    """
  end

  attr :option, :map, required: true
  attr :id, :string, required: true, doc: "the preview's test id"

  @doc "An option's example, folded, rendered as Markdown."
  @spec option_preview(map()) :: Phoenix.LiveView.Rendered.t()
  def option_preview(assigns) do
    ~H"""
    <details :if={@option["preview"] not in [nil, ""]} class="mt-2 text-sm" data-testid={@id}>
      <summary class="cursor-pointer text-primary-600 dark:text-primary-400">Ver exemplo</summary>
      <div class="prose prose-sm mt-2 max-w-none overflow-x-auto dark:prose-invert">
        {Markdown.to_html(@option["preview"])}
      </div>
    </details>
    """
  end

  attr :analysis, :atom, required: true, values: [:none, :running, :failed]
  attr :key, :string, default: nil

  @doc "How the automatic analysis of a failure goes, while there is no questionnaire."
  @spec analysis_state(map()) :: Phoenix.LiveView.Rendered.t()
  def analysis_state(assigns) do
    ~H"""
    <div
      :if={@analysis == :running}
      class="mt-3 flex items-center gap-2 text-sm text-gray-600 dark:text-gray-300"
      data-testid={testid("questionnaire-analyzing", @key)}
    >
      <.spinner size="sm" /> O agente está analisando a falha…
    </div>
    <.alert
      :if={@analysis == :failed}
      color="gray"
      with_icon
      class="mt-3"
      data-testid={testid("questionnaire-analysis-failed", @key)}
    >
      A análise não ficou pronta; decida manualmente abaixo.
    </.alert>
    """
  end

  attr :answers, :map, required: true, doc: "`%{\"perguntas\", \"respostas\"}`"
  attr :class, :any, default: "space-y-1 text-sm"
  attr :rest, :global

  @doc "Each question with the answer it got, in a short list."
  @spec answer_list(map()) :: Phoenix.LiveView.Rendered.t()
  def answer_list(assigns) do
    ~H"""
    <ul class={@class} {@rest}>
      <li :for={
        {question, answer} <-
          Enum.zip(
            @answers["perguntas"] || [],
            (@answers["respostas"] || []) ++ List.duplicate(nil, 4)
          )
      }>
        <span class="text-gray-600 dark:text-gray-300">{question["pergunta"]}</span>
        <span class="font-medium text-gray-900 dark:text-white">
          → {Questionnaire.answer_text(answer)}
        </span>
      </li>
    </ul>
    """
  end
end
