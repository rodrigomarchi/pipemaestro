defmodule PipeMaestro.Tasks.QuestionnaireTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Tasks.Questionnaire

  defp option(rotulo, attrs \\ %{}) do
    Map.merge(
      %{"rotulo" => rotulo, "descricao" => "Sobre #{rotulo}", "recomendada" => false},
      attrs
    )
  end

  defp question(attrs \\ %{}) do
    Map.merge(
      %{
        "titulo" => "Navegador",
        "pergunta" => "Em qual navegador reproduz?",
        "multipla" => false,
        "opcoes" => [option("Chrome"), option("Safari 17", %{"recomendada" => true})]
      },
      attrs
    )
  end

  describe "normalize/1" do
    test "keeps a valid list of questions, the recommended option first" do
      assert {:ok, [normalized]} = Questionnaire.normalize([question()])

      assert normalized["titulo"] == "Navegador"
      assert normalized["pergunta"] == "Em qual navegador reproduz?"
      assert normalized["multipla"] == false
      assert Enum.map(normalized["opcoes"], & &1["rotulo"]) == ["Safari 17", "Chrome"]
      assert hd(normalized["opcoes"])["recomendada"] == true
    end

    test "keeps an option's preview, and no preview is nil" do
      opcoes = [option("A", %{"preview" => "```elixir\nx\n```"}), option("B")]
      assert {:ok, [q]} = Questionnaire.normalize([question(%{"opcoes" => opcoes})])

      assert Enum.find(q["opcoes"], &(&1["rotulo"] == "A"))["preview"] == "```elixir\nx\n```"
      assert Enum.find(q["opcoes"], &(&1["rotulo"] == "B"))["preview"] == nil
    end

    test "accepts from one to four questions" do
      assert {:ok, [_]} = Questionnaire.normalize([question()])
      assert {:ok, four} = Questionnaire.normalize(List.duplicate(question(), 4))
      assert length(four) == 4

      assert Questionnaire.normalize([]) == :error
      assert Questionnaire.normalize(List.duplicate(question(), 5)) == :error
    end

    test "each question has from two to four options" do
      assert Questionnaire.normalize([question(%{"opcoes" => [option("A")]})]) == :error

      five = for label <- ~w(A B C D E), do: option(label)
      assert Questionnaire.normalize([question(%{"opcoes" => five})]) == :error

      four = for label <- ~w(A B C D), do: option(label)
      assert {:ok, [_]} = Questionnaire.normalize([question(%{"opcoes" => four})])
    end

    test "a question must end with a question mark" do
      assert Questionnaire.normalize([question(%{"pergunta" => "Escolha o navegador"})]) ==
               :error
    end

    test "cuts the title to 12 characters and an option's label to 5 words" do
      long =
        question(%{
          "titulo" => "Um título comprido demais",
          "opcoes" => [
            option("um dois três quatro cinco seis sete"),
            option("Outra")
          ]
        })

      assert {:ok, [q]} = Questionnaire.normalize([long])
      assert String.length(q["titulo"]) <= 12
      assert q["titulo"] == String.slice("Um título comprido demais", 0, 12)
      assert "um dois três quatro cinco" in Enum.map(q["opcoes"], & &1["rotulo"])
    end

    test "anything that is not a list of questions is refused" do
      assert Questionnaire.normalize(nil) == :error
      assert Questionnaire.normalize("Qual navegador?") == :error
      assert Questionnaire.normalize([%{"pergunta" => "Sem opções?"}]) == :error
      assert Questionnaire.normalize(["texto solto"]) == :error
    end
  end

  describe "from_options/1" do
    test "the old options become a single question, one option per phrase" do
      assert [q] = Questionnaire.from_options(["No cliente", "No servidor"])

      assert q["titulo"] == "Caminho"
      assert q["pergunta"] == "Como a etapa deve seguir?"
      assert q["multipla"] == false
      assert Enum.map(q["opcoes"], & &1["rotulo"]) == ["No cliente", "No servidor"]
      assert Enum.all?(q["opcoes"], &(&1["descricao"] == ""))
    end

    test "a single phrase is enough: Other completes the choice" do
      assert [%{"opcoes" => [%{"rotulo" => "Só esta"}]}] = Questionnaire.from_options(["Só esta"])
    end
  end

  describe "for_run/1" do
    test "valid questions come from the agent" do
      output = %{"status" => "bloqueado", "resumo" => "r", "perguntas" => [question()]}

      assert %{"origem" => "agente", "perguntas" => [%{"titulo" => "Navegador"}]} =
               Questionnaire.for_run(output)
    end

    test "without valid questions, the old options become one" do
      output = %{
        "status" => "bloqueado",
        "resumo" => "r",
        "perguntas" => [%{"pergunta" => "inválida"}],
        "opcoes" => ["No cliente", "No servidor"]
      }

      assert %{"origem" => "opcoes", "perguntas" => [%{"titulo" => "Caminho"}]} =
               Questionnaire.for_run(output)
    end

    test "nothing to ask is nil" do
      assert Questionnaire.for_run(%{"status" => "bloqueado", "resumo" => "r"}) == nil
      assert Questionnaire.for_run(%{"status" => "bloqueado", "opcoes" => []}) == nil
      assert Questionnaire.for_run(nil) == nil
    end
  end

  describe "validate_answers/2" do
    setup do
      multiple =
        question(%{
          "titulo" => "Telas",
          "pergunta" => "Quais telas mudam?",
          "multipla" => true,
          "opcoes" => [option("Board"), option("Decisões"), option("Tarefa")]
        })

      %{questions: [question(), multiple]}
    end

    test "one answer per question, choices among the labels offered", %{questions: questions} do
      answers = [
        %{"escolhas" => ["Safari 17"], "outro" => nil},
        %{"escolhas" => ["Board", "Decisões"], "outro" => nil}
      ]

      assert {:ok, ^answers} = Questionnaire.validate_answers(questions, answers)
    end

    test "Other filled in answers a question by itself", %{questions: questions} do
      answers = [
        %{"escolhas" => [], "outro" => "No Firefox"},
        %{"escolhas" => ["Board"], "outro" => "e o menu"}
      ]

      assert {:ok, _} = Questionnaire.validate_answers(questions, answers)
    end

    test "a question without a choice or with a blank Other is not answered",
         %{questions: questions} do
      assert {:error, _} =
               Questionnaire.validate_answers(questions, [
                 %{"escolhas" => [], "outro" => "   "},
                 %{"escolhas" => ["Board"], "outro" => nil}
               ])
    end

    test "a single-choice question takes one choice", %{questions: questions} do
      assert {:error, _} =
               Questionnaire.validate_answers(questions, [
                 %{"escolhas" => ["Chrome", "Safari 17"], "outro" => nil},
                 %{"escolhas" => ["Board"], "outro" => nil}
               ])
    end

    test "a choice that was not offered is refused", %{questions: questions} do
      assert {:error, _} =
               Questionnaire.validate_answers(questions, [
                 %{"escolhas" => ["Edge"], "outro" => nil},
                 %{"escolhas" => ["Board"], "outro" => nil}
               ])
    end

    test "the number of answers must match the questions", %{questions: questions} do
      assert {:error, _} =
               Questionnaire.validate_answers(questions, [
                 %{"escolhas" => ["Chrome"], "outro" => nil}
               ])
    end
  end

  test "to_markdown/2 pairs each question with its answer" do
    multiple =
      question(%{
        "titulo" => "Telas",
        "pergunta" => "Quais telas mudam?",
        "multipla" => true,
        "opcoes" => [option("Board"), option("Decisões")]
      })

    text =
      Questionnaire.to_markdown([question(), multiple], [
        %{"escolhas" => ["Safari 17"], "outro" => nil},
        %{"escolhas" => ["Board", "Decisões"], "outro" => "e o menu"}
      ])

    assert text =~ "Em qual navegador reproduz?"
    assert text =~ "Safari 17"
    assert text =~ "Quais telas mudam?"
    assert text =~ "Board"
    assert text =~ "Decisões"
    assert text =~ "e o menu"
  end
end
