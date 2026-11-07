defmodule PipeMaestroWeb.AgentOutputTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PipeMaestroWeb.AgentOutput

  defp output(text),
    do: render_component(&AgentOutput.agent_output/1, id: "out", text: text)

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text() |> String.trim()

  describe "parse/1" do
    test "a JSON object is its fields, in the agent's order" do
      assert AgentOutput.parse(~s({"status":"ok","resumo":"feito","arquivos":["a"]})) ==
               {:fields, [{"status", "ok"}, {"resumo", "feito"}, {"arquivos", ["a"]}]}
    end

    test "a JSON array is indented JSON; anything else is Markdown" do
      assert {:json, json} = AgentOutput.parse(~s( [1, {"a": true}] ))
      assert json =~ ~s(\n  1,)

      assert AgentOutput.parse("**feito**") == {:markdown, "**feito**"}
      assert AgentOutput.parse("{não é json") == {:markdown, "{não é json"}
    end
  end

  describe "agent_output/1" do
    test "shows the status as a badge and each field as what it holds" do
      html =
        output(
          Jason.encode!(%{
            "status" => "bloqueado",
            "resumo" => "Falta decidir o **nome**.",
            "perguntas" => [%{"pergunta" => "Qual nome?", "opcoes" => ["a", "b"]}],
            "arquivos" => ["`lib/a.ex`", "`lib/b.ex`"],
            "custo" => 2,
            "pr" => nil
          })
        )

      assert text(html, "[data-testid=agent-output-status]") == "bloqueado"
      assert text(html, "[data-testid=agent-output-field-resumo] strong") == "nome"

      assert html |> query("[data-testid=agent-output-field-arquivos] li code") |> Enum.count() ==
               2

      assert text(html, "[data-testid=agent-output-field-perguntas] code.language-json") =~
               ~s("pergunta": "Qual nome?")

      assert text(html, "[data-testid=agent-output-field-custo]") =~ "2"
      assert text(html, "[data-testid=agent-output-field-pr]") =~ "—"
      refute html =~ "agent-output-field-status"
    end

    test "Markdown is rendered; a JSON array is indented and marked for highlighting" do
      assert text(output("# Pronto\n\nTudo *certo*."), "h1") == "Pronto"
      assert output("# Pronto") =~ ~s(data-format="markdown")

      html = output(~s([{"a":1}]))
      assert html =~ ~s(data-format="json")
      assert text(html, "code.language-json") =~ ~s("a": 1)
    end
  end
end
