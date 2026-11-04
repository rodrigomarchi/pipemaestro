defmodule PipeMaestroWeb.QuestionnaireComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestroWeb.QuestionnaireComponents

  @questionnaire %{
    "origem" => "analise",
    "diagnostico" => "O teste falha porque o **timeout** é curto.",
    "perguntas" => [
      %{
        "titulo" => "Navegador",
        "pergunta" => "Em qual navegador reproduz?",
        "multipla" => false,
        "opcoes" => [
          %{
            "rotulo" => "Safari 17",
            "descricao" => "Onde o bug apareceu",
            "recomendada" => true,
            "preview" => "```elixir\nSafari.open()\n```"
          },
          %{"rotulo" => "Chrome", "descricao" => "O mais usado", "recomendada" => false}
        ]
      }
    ]
  }

  test "read-only: the diagnosis, the questions and the recommended option" do
    html =
      render_component(&QuestionnaireComponents.questionnaire/1, questionnaire: @questionnaire)

    assert html =~ ~s(data-testid="questionnaire")
    assert html =~ ~s(data-testid="questionnaire-diagnosis")
    assert html =~ "<strong>timeout</strong>"
    assert html =~ "Em qual navegador reproduz?"
    assert html =~ "Navegador"
    assert html =~ "Safari 17"
    assert html =~ "recomendada"
    assert html =~ ~s(data-testid="question-0-preview-0")
    assert html =~ "Safari.open()"
    # Read-only: nothing to send.
    refute html =~ ~s(data-testid="questionnaire-submit")
  end

  test "read-only with answers: each question with what the person answered" do
    html =
      render_component(&QuestionnaireComponents.questionnaire/1,
        questionnaire: @questionnaire,
        answers: [%{"escolhas" => ["Chrome"], "outro" => "e no iPad"}]
      )

    assert html =~ "Em qual navegador reproduz?"
    assert html =~ "Chrome"
    assert html =~ "e no iPad"
  end

  test "the ids carry the key on a page with several questionnaires" do
    html =
      render_component(&QuestionnaireComponents.questionnaire/1,
        questionnaire: @questionnaire,
        key: "t1"
      )

    assert html =~ ~s(data-testid="questionnaire-t1")
    assert html =~ ~s(data-testid="question-0-t1")
  end
end
