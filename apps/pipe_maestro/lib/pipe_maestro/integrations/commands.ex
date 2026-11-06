defmodule PipeMaestro.Integrations.Commands do
  @moduledoc """
  The commands a person writes in a comment on the issue or the pull request
  of a task (`docs/specs/integracoes.md`, section 6): the first line that
  starts with the command (`/pipemaestro`, or the repository's comment
  trigger's), then a word and, for some, instructions:

      /pipemaestro seguir use a opção B
      /pipemaestro refazer
      /pipemaestro responder
      1. Postgres
      2. Board, Decisões
      /pipemaestro pausar
      /pipemaestro cancelar
      /pipemaestro corrigir falta o teste do e-mail com espaço
  """

  @actions %{
    "seguir" => :advance,
    "refazer" => :retry,
    "responder" => :answer,
    "pausar" => :pause,
    "cancelar" => :cancel,
    "corrigir" => :correct
  }

  @typedoc "A command: the action, and the text that came with it."
  @type t :: %{
          action: :advance | :retry | :answer | :pause | :cancel | :correct,
          text: String.t()
        }

  @doc """
  The command in `body`, if a line starts with `command`: `{:ok, command}`,
  `{:unknown, word}` for a word that is no command (or none), `:none` for a
  comment without the command.
  """
  @spec parse(String.t(), String.t()) :: {:ok, t()} | {:unknown, String.t()} | :none
  def parse(body, command) do
    lines = String.split(body || "", ~r/\r?\n/)
    prefix = String.downcase(command)

    case Enum.split_while(lines, &(not starts_with_command?(&1, prefix))) do
      {_before, []} ->
        :none

      {_before, [line | rest]} ->
        line = String.trim(line)
        after_command = line |> String.slice(String.length(command)..-1//1) |> String.trim()
        [word | words] = String.split(after_command, ~r/\s+/, parts: 2) ++ [""]
        same_line = words |> List.first() |> Kernel.||("") |> String.trim()
        text = [same_line | rest] |> Enum.join("\n") |> String.trim()

        case Map.fetch(@actions, String.downcase(word)) do
          {:ok, action} -> {:ok, %{action: action, text: text}}
          :error -> {:unknown, word}
        end
    end
  end

  defp starts_with_command?(line, prefix) do
    line = line |> String.trim() |> String.downcase()
    line == prefix or String.starts_with?(line, prefix <> " ")
  end

  @doc "The word a person writes for `action`."
  @spec word(atom()) :: String.t()
  def word(action),
    do:
      Enum.find_value(@actions, fn
        {word, ^action} -> word
        _other -> nil
      end)

  @doc """
  The answers in a `responder` text, one numbered line per question, in the
  form `PipeMaestro.Tasks.Questionnaire` takes: the options named (by label,
  any case, separated by commas) and, for the rest, the free text.
  """
  @spec answers(String.t(), [map()]) :: [map()]
  def answers(text, questions) do
    lines =
      for line <- String.split(text, ~r/\r?\n/),
          [_, n, answer] <- [Regex.run(~r/^\s*(\d+)[.)]\s*(.+)$/, line)],
          into: %{},
          do: {String.to_integer(n), String.trim(answer)}

    questions
    |> Enum.with_index(1)
    |> Enum.map(fn {question, n} -> answer(question, Map.get(lines, n)) end)
  end

  defp answer(_question, nil), do: %{"escolhas" => [], "outro" => nil}

  defp answer(question, text) do
    labels = Map.new(question["opcoes"] || [], &{String.downcase(&1["rotulo"]), &1["rotulo"]})
    parts = text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    {known, other} = Enum.split_with(parts, &Map.has_key?(labels, String.downcase(&1)))

    %{
      "escolhas" => Enum.map(known, &labels[String.downcase(&1)]),
      "outro" => if(other == [], do: nil, else: Enum.join(other, ", "))
    }
  end

  @doc "What a person can write, for an answer to a command that does not apply."
  @spec help(String.t()) :: String.t()
  def help(command) do
    """
    Não entendi o comando. Com uma tarefa em andamento, use:

    - `#{command} seguir [instruções]` ou `#{command} refazer [instruções]`, quando ela espera uma decisão;
    - `#{command} responder` e, nas linhas seguintes, `1. resposta`, para as perguntas;
    - `#{command} pausar` ou `#{command} cancelar`;
    - `#{command} corrigir <pedido>`, quando ela já terminou.
    """
  end
end
