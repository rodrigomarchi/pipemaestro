defmodule PipeMaestro.Integrations.CommandsTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Integrations.Commands

  test "reads each command and the text that follows" do
    assert Commands.parse("/pipemaestro seguir use a opção B", "/pipemaestro") ==
             {:ok, %{action: :advance, text: "use a opção B"}}

    assert Commands.parse("/pipemaestro refazer", "/pipemaestro") ==
             {:ok, %{action: :retry, text: ""}}

    assert Commands.parse("/pipemaestro pausar", "/pipemaestro") ==
             {:ok, %{action: :pause, text: ""}}

    assert Commands.parse("/pipemaestro cancelar", "/pipemaestro") ==
             {:ok, %{action: :cancel, text: ""}}

    assert Commands.parse(
             "/pipemaestro corrigir falta um teste\ncom espaço no e-mail",
             "/pipemaestro"
           ) ==
             {:ok, %{action: :correct, text: "falta um teste\ncom espaço no e-mail"}}

    assert Commands.parse("/pipemaestro responder\n1. Postgres", "/pipemaestro") ==
             {:ok, %{action: :answer, text: "1. Postgres"}}
  end

  test "finds the command on any line, in any case, with the repository's command" do
    assert {:ok, %{action: :advance}} =
             Commands.parse("Olhei.\n  /PipeMaestro  Seguir  ", "/pipemaestro")

    assert {:ok, %{action: :cancel}} = Commands.parse("/pm cancelar", "/pm")
  end

  test "tells a comment without the command from a word that is no command" do
    assert Commands.parse("Alguém viu isso?", "/pipemaestro") == :none
    assert Commands.parse("veja /pipemaestro seguir", "/pipemaestro") == :none
    assert Commands.parse("/pipemaestroseguir", "/pipemaestro") == :none
    assert Commands.parse("/pipemaestro", "/pipemaestro") == {:unknown, ""}
    assert Commands.parse("/pipemaestro dançar", "/pipemaestro") == {:unknown, "dançar"}
  end

  test "reads the answers by line, the options by label and the rest as free text" do
    questions = [
      %{
        "pergunta" => "Qual banco?",
        "opcoes" => [%{"rotulo" => "Postgres"}, %{"rotulo" => "MySQL"}]
      },
      %{
        "pergunta" => "Quais telas?",
        "multipla" => true,
        "opcoes" => [%{"rotulo" => "Board"}, %{"rotulo" => "Decisões"}]
      },
      %{"pergunta" => "Algo mais?", "opcoes" => [%{"rotulo" => "Não"}, %{"rotulo" => "Sim"}]}
    ]

    assert Commands.answers("1. postgres\n2) Board, decisões\n3. o limite é 2 s", questions) == [
             %{"escolhas" => ["Postgres"], "outro" => nil},
             %{"escolhas" => ["Board", "Decisões"], "outro" => nil},
             %{"escolhas" => [], "outro" => "o limite é 2 s"}
           ]

    assert [_, _, %{"escolhas" => [], "outro" => nil}] =
             Commands.answers("1. MySQL\n2. Board", questions)
  end

  test "names each action by its word" do
    assert Commands.word(:advance) == "seguir"
    assert Commands.word(:correct) == "corrigir"
  end

  test "explains the commands" do
    assert Commands.help("/pm") =~ "`/pm seguir [instruções]`"
  end
end
