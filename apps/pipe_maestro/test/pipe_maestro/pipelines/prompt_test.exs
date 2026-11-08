defmodule PipeMaestro.Pipelines.PromptTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Pipelines.{Prompt, Stage}

  @stage %Stage{key: "a", name: "Etapa A", prompt: "Faça A: {{tarefa.descricao}}"}

  defp context(extra \\ %{}) do
    Map.merge(
      %{
        task_id: "t1",
        title: "Corrigir o login",
        description: "O botão não responde",
        directory: "app",
        stage_index: 0,
        previous: []
      },
      extra
    )
  end

  describe "the output schema" do
    test "has structured questions, within the limits the platform enforces" do
      perguntas = Prompt.output_schema(%Stage{})["properties"]["perguntas"]

      assert perguntas["type"] == "array"
      assert perguntas["minItems"] == 1
      assert perguntas["maxItems"] == 4
      assert perguntas == Prompt.questions_schema()

      question = perguntas["items"]
      assert question["properties"]["titulo"]["maxLength"] == 12
      assert Enum.sort(question["required"]) == Enum.sort(~w(titulo pergunta multipla opcoes))

      options = question["properties"]["opcoes"]
      assert options["minItems"] == 2
      assert options["maxItems"] == 4

      assert Enum.sort(options["items"]["required"]) ==
               Enum.sort(~w(rotulo descricao recomendada))

      assert Map.has_key?(options["items"]["properties"], "preview")
    end

    test "keeps the old options, marked obsolete, and no if/then" do
      schema = Prompt.output_schema(%Stage{})

      assert schema["properties"]["opcoes"]["description"] =~ "obsoleto"
      assert schema["required"] == ["status", "resumo"]
      refute Map.has_key?(schema, "if")
      refute Map.has_key?(schema, "allOf")
    end

    test "a stage's own fields keep the questions" do
      stage = %Stage{output_schema: %{"properties" => %{"risco" => %{"type" => "string"}}}}
      assert Map.has_key?(Prompt.output_schema(stage)["properties"], "perguntas")
    end
  end

  describe "build/2" do
    test "a runner that uploads files learns to copy them to CP_FILES_DIR" do
      prompt = Prompt.build(@stage, context(%{files: true}))

      assert prompt =~ "$CP_FILES_DIR"
      assert prompt =~ "copiados"
    end

    test "without the files capability, the prompt says nothing about CP_FILES_DIR" do
      refute Prompt.build(@stage, context()) =~ "CP_FILES_DIR"
      refute Prompt.build(@stage, context(%{files: false})) =~ "CP_FILES_DIR"
    end

    test "the fixed header teaches to ask through `perguntas`, with no AskUserQuestion" do
      prompt = Prompt.build(@stage, context())

      assert prompt =~ "perguntas"
      assert prompt =~ "AskUserQuestion"
      assert prompt =~ ~s(status "bloqueado")
    end

    test "the person's answers come in their own section, after the feedback" do
      questions = [
        %{
          "titulo" => "Navegador",
          "pergunta" => "Em qual navegador reproduz?",
          "multipla" => false,
          "opcoes" => [
            %{"rotulo" => "Safari 17", "descricao" => "", "recomendada" => true},
            %{"rotulo" => "Chrome", "descricao" => "", "recomendada" => false}
          ]
        }
      ]

      answers = %{
        "perguntas" => questions,
        "respostas" => [%{"escolhas" => ["Safari 17"], "outro" => "e no iPad"}]
      }

      prompt =
        Prompt.build(
          @stage,
          context(%{feedback: "A tentativa anterior falhou.", answers: answers})
        )

      assert prompt =~ "Respostas da pessoa às suas perguntas"
      assert prompt =~ "Em qual navegador reproduz?"
      assert prompt =~ "Safari 17"
      assert prompt =~ "e no iPad"

      {feedback_at, _} = :binary.match(prompt, "A tentativa anterior falhou.")
      {answers_at, _} = :binary.match(prompt, "Respostas da pessoa às suas perguntas")
      assert answers_at > feedback_at
    end

    test "the stage's gates are listed, as the runner will run them, after the contract" do
      gates = [
        %{"command" => "mix format --check-formatted", "expect" => "pass"},
        %{"command" => "mix test", "expect" => "fail"}
      ]

      prompt =
        Prompt.build(@stage, context(%{gates: gates, contract: "# Contrato com a plataforma"}))

      assert prompt =~ "# Gates desta etapa"
      assert prompt =~ "- `mix format --check-formatted` (deve passar)"
      assert prompt =~ "- `mix test` (deve falhar)"
      assert prompt =~ "Não é preciso rodar os gates só para ver o que vão dizer"

      {contract_at, _} = :binary.match(prompt, "# Contrato com a plataforma")
      {gates_at, _} = :binary.match(prompt, "# Gates desta etapa")
      assert gates_at > contract_at
    end

    test "a stage without gates has no gates section" do
      refute Prompt.build(@stage, context()) =~ "Gates desta etapa"
      refute Prompt.build(@stage, context(%{gates: nil})) =~ "Gates desta etapa"
      refute Prompt.build(@stage, context(%{gates: []})) =~ "Gates desta etapa"
    end

    test "without answers there is no answers section" do
      refute Prompt.build(@stage, context()) =~ "Respostas da pessoa"
      refute Prompt.build(@stage, context(%{answers: nil})) =~ "Respostas da pessoa"
    end
  end
end
