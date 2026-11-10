defmodule PipeMaestro.Tasks.Questionnaire do
  @moduledoc """
  The questions a task asks a person when it pauses, and the person's answers.

  A questionnaire is a map with string keys, kept as jsonb:

      %{
        "origem" => "agente" | "opcoes" | "analise",
        "diagnostico" => "Markdown" | nil,
        "perguntas" => [question()]
      }

  `origem` says where the questions came from: the agent that blocked
  (`perguntas` in its structured output), the old `opcoes` turned into a
  single question (`from_options/1`), or the automatic analysis of a failure
  (`PipeMaestro.Proposals.AnalysisKind`), which also brings a diagnosis.

  Each question has from 2 to 4 options, the recommended one first; "Outro"
  (free text) is always offered on top of them, so it is not in the data.
  The answers are a list aligned with the questions (`answer()`).

  Pure: no database, so the limits the platform enforces read in one place.
  """

  @max_questions 4
  @min_options 2
  @max_options 4
  @title_length 12
  @label_words 5

  @typedoc "One option of a question."
  @type option :: %{
          required(String.t()) => String.t() | boolean() | nil
        }

  @typedoc """
  A question: `"titulo"` (a short tag), `"pergunta"` (ends with "?"),
  `"multipla"` (several choices allowed) and `"opcoes"` (each with
  `"rotulo"`, `"descricao"`, `"recomendada"` and `"preview"`).
  """
  @type question :: %{required(String.t()) => String.t() | boolean() | [option()]}

  @typedoc """
  The answer to one question: the labels chosen (`"escolhas"`) and the free
  text of "Outro" (`"outro"`).
  """
  @type answer :: %{required(String.t()) => [String.t()] | String.t() | nil}

  @typedoc "A questionnaire as a task keeps it."
  @type t :: %{required(String.t()) => String.t() | [question()] | nil}

  @doc """
  Reads the agent's `perguntas` defensively: `{:ok, questions}` within the
  limits, `:error` otherwise. Titles longer than 12 characters and labels
  longer than 5 words are cut rather than refused; the recommended options
  come first.
  """
  @spec normalize(term()) :: {:ok, [question()]} | :error
  def normalize(questions)
      when is_list(questions) and questions != [] and length(questions) <= @max_questions do
    questions
    |> Enum.map(&normalize_question/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, question}, {:ok, acc} -> {:cont, {:ok, [question | acc]}}
      :error, _acc -> {:halt, :error}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  def normalize(_not_questions), do: :error

  defp normalize_question(
         %{"pergunta" => pergunta, "opcoes" => options, "titulo" => titulo} = question
       )
       when is_binary(pergunta) and is_binary(titulo) and is_list(options) and
              length(options) in @min_options..@max_options do
    pergunta = String.trim(pergunta)
    options = Enum.map(options, &normalize_option/1)

    if String.ends_with?(pergunta, "?") and Enum.all?(options, &is_map/1) do
      {:ok,
       %{
         "titulo" => titulo |> String.trim() |> String.slice(0, @title_length),
         "pergunta" => pergunta,
         "multipla" => question["multipla"] == true,
         "opcoes" => Enum.sort_by(options, &(not &1["recomendada"]))
       }}
    else
      :error
    end
  end

  defp normalize_question(_invalid), do: :error

  defp normalize_option(%{"rotulo" => rotulo} = option) when is_binary(rotulo) do
    label = rotulo |> String.split() |> Enum.take(@label_words) |> Enum.join(" ")

    if label == "" do
      nil
    else
      %{
        "rotulo" => label,
        "descricao" => text(option["descricao"]),
        "recomendada" => option["recomendada"] == true,
        "preview" => preview(option["preview"])
      }
    end
  end

  defp normalize_option(_invalid), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""

  defp preview(value) when is_binary(value) and value != "", do: value
  defp preview(_other), do: nil

  @doc """
  The old `opcoes` (phrases) as a single question, one option per phrase.
  One phrase is enough: "Outro" completes the choice.
  """
  @spec from_options([String.t()]) :: [question()]
  def from_options(options) do
    [
      %{
        "titulo" => "Caminho",
        "pergunta" => "Como a etapa deve seguir?",
        "multipla" => false,
        "opcoes" =>
          for option <- options do
            %{"rotulo" => option, "descricao" => "", "recomendada" => false, "preview" => nil}
          end
      }
    ]
  end

  @doc """
  The questionnaire of a stage run's structured output: its valid
  `perguntas`, else its `opcoes` as one question, else `nil`.
  """
  @spec for_run(map() | nil) :: t() | nil
  def for_run(%{} = output) do
    case normalize(output["perguntas"]) do
      {:ok, questions} ->
        %{"origem" => "agente", "perguntas" => questions}

      :error ->
        case phrases(output["opcoes"]) do
          [] -> nil
          options -> %{"origem" => "opcoes", "perguntas" => from_options(options)}
        end
    end
  end

  def for_run(_no_output), do: nil

  defp phrases(options) when is_list(options),
    do: options |> Enum.filter(&is_binary/1) |> Enum.reject(&(String.trim(&1) == ""))

  defp phrases(_other), do: []

  @doc """
  Checks that `answers` answer every question: one answer per question, with
  at least one choice or a filled-in "Outro", a single choice when the
  question takes one, and choices among the labels offered.
  """
  @spec validate_answers([question()], term()) :: {:ok, [answer()]} | {:error, String.t()}
  def validate_answers(questions, answers), do: validate(questions, answers, true)

  @doc """
  Like `validate_answers/2`, but a question may stay unanswered: what is
  answered must still be valid. For going on without every answer.
  """
  @spec validate_partial([question()], term()) :: {:ok, [answer()]} | {:error, String.t()}
  def validate_partial(questions, answers), do: validate(questions, answers, false)

  defp validate(questions, answers, required?) when is_list(answers) do
    with :ok <- check_count(questions, answers) do
      questions
      |> Enum.zip(answers)
      |> Enum.with_index(1)
      |> Enum.find_value({:ok, answers}, &answer_error(&1, required?))
    end
  end

  defp validate(_questions, _answers, _required?),
    do: {:error, "As respostas não são uma lista."}

  defp answer_error({{question, answer}, n}, required?) do
    case check_answer(question, answer, required?) do
      :ok -> nil
      {:error, reason} -> {:error, "Pergunta #{n}: #{reason}"}
    end
  end

  defp check_count(questions, answers) do
    if length(questions) == length(answers),
      do: :ok,
      else: {:error, "Responda às #{length(questions)} pergunta(s)."}
  end

  defp check_answer(question, %{} = answer, required?) do
    choices = choices(answer)
    labels = Enum.map(question["opcoes"], & &1["rotulo"])

    cond do
      required? and choices == [] and other(answer) == nil ->
        {:error, "escolha uma opção ou escreva em \"Outro\"."}

      not question["multipla"] and length(choices) > 1 ->
        {:error, "escolha uma só opção."}

      Enum.any?(choices, &(&1 not in labels)) ->
        {:error, "escolha entre as opções oferecidas."}

      true ->
        :ok
    end
  end

  defp check_answer(_question, _answer, _required?), do: {:error, "resposta inválida."}

  @doc "Whether `answer` answers its question: a choice, or a filled-in \"Outro\"."
  @spec answered?(answer() | nil) :: boolean()
  def answered?(%{} = answer), do: choices(answer) != [] or other(answer) != nil
  def answered?(_none), do: false

  @doc "The labels chosen in an answer."
  @spec choices(answer() | nil) :: [String.t()]
  def choices(%{"escolhas" => choices}) when is_list(choices),
    do: Enum.filter(choices, &(is_binary(&1) and &1 != ""))

  def choices(_none), do: []

  @doc "The \"Outro\" text of an answer, trimmed, or `nil` when blank."
  @spec other(answer() | nil) :: String.t() | nil
  def other(%{"outro" => text}) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  def other(_none), do: nil

  @doc """
  Each question with its answer, as Markdown: for the next attempt's prompt,
  the issue comment and the history.
  """
  @spec to_markdown([question()], [answer()]) :: String.t()
  def to_markdown(questions, answers) do
    questions
    |> Enum.zip(answers ++ List.duplicate(nil, max(length(questions) - length(answers), 0)))
    |> Enum.map_join("\n", fn {question, answer} ->
      "- **#{question["pergunta"]}** #{answer_text(answer)}"
    end)
  end

  @doc """
  A question in one line, for plain Markdown (an issue comment, a reason):
  the question, then its options, the recommended one marked.
  """
  @spec question_text(question()) :: String.t()
  def question_text(question) do
    options =
      Enum.map_join(question["opcoes"] || [], " · ", fn option ->
        if option["recomendada"],
          do: "#{option["rotulo"]} (recomendada)",
          else: option["rotulo"]
      end)

    if options == "",
      do: question["pergunta"],
      else: "#{question["pergunta"]} — #{options}"
  end

  @doc "The questions numbered, one per line (`question_text/1`); empty without any."
  @spec to_text([question()]) :: String.t()
  def to_text(questions) do
    questions
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {question, n} -> "#{n}. #{question_text(question)}" end)
  end

  @doc "An answer in words: the choices and the \"Outro\" text, or that it went unanswered."
  @spec answer_text(answer() | nil) :: String.t()
  def answer_text(answer) do
    case Enum.reject(choices(answer) ++ [other(answer)], &is_nil/1) do
      [] -> "(sem resposta)"
      parts -> Enum.join(parts, "; ")
    end
  end
end
