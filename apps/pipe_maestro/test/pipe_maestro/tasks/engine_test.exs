defmodule PipeMaestro.Tasks.EngineTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Tasks.Engine

  describe "feedback/3" do
    test "the error, what the agent said, and each failed gate's output in a code block" do
      feedback =
        Engine.feedback("gate falhou", "Mudei o `login`.", [
          %{"command" => "mix format", "passed" => true, "output" => ""},
          %{
            "command" => "mix test",
            "passed" => false,
            "exit_code" => 1,
            "output" => "1 failure"
          },
          %{
            "platform" => true,
            "command" => "plataforma: branch",
            "passed" => false,
            "message" => "não"
          }
        ])

      assert feedback ==
               Enum.join(
                 [
                   "Erro: gate falhou",
                   "O que a tentativa disse ter feito: Mudei o `login`.",
                   "Saída de `mix test` (código 1):\n```\n1 failure\n```",
                   "plataforma: branch: não"
                 ],
                 "\n\n"
               )
    end

    test "a fence longer than any backticks in the output, so it cannot close early" do
      feedback =
        Engine.feedback(nil, nil, [
          %{"command" => "x", "passed" => false, "exit_code" => 1, "output" => "a ``` b"}
        ])

      assert feedback == "Saída de `x` (código 1):\n````\na ``` b\n````"
    end
  end
end
