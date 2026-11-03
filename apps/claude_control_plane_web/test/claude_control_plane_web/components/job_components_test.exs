defmodule ClaudeControlPlaneWeb.JobComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.Jobs.Event
  alias ClaudeControlPlaneWeb.JobComponents

  defp render_event(type, data) do
    render_component(&JobComponents.job_event/1,
      id: "e1",
      event: %Event{id: 1, seq: 1, type: type, data: data}
    )
  end

  defp tool(name, input), do: render_event("tool_use", %{"name" => name, "input" => input})

  test "the session start says which credential and permission mode it ran with" do
    html =
      render_event("system", %{
        "text" => "Sessão iniciada (haiku)",
        "auth" => "none",
        "permission_mode" => "dontAsk"
      })

    assert html =~ "login pessoal"
    assert html =~ "dontAsk"

    assert render_event("system", %{"text" => "x", "auth" => "ANTHROPIC_API_KEY"}) =~
             "chave de API"
  end

  test "the agent's text is rendered Markdown" do
    html = render_event("assistant_text", %{"text" => "Achei o **bug** em `login.ex`"})
    assert html =~ "<strong>bug</strong>"
    assert html =~ "<code>login.ex</code>"
  end

  test "a shell command shows as one, with what it is for" do
    html = tool("Bash", %{"command" => "mix test", "description" => "Roda a suíte"})
    assert html =~ "$ mix test"
    assert html =~ "Roda a suíte"
  end

  test "an edit shows as a diff of the file" do
    html =
      tool("Edit", %{"file_path" => "/w/lib/a.ex", "old_string" => "a\nb", "new_string" => "c"})

    assert html =~ "/w/lib/a.ex"
    assert html =~ ~r/class="[^"]*diff-del[^"]*">-a</
    assert html =~ ~r/class="[^"]*diff-del[^"]*">-b</
    assert html =~ ~r/class="[^"]*diff-add[^"]*">\+c</
  end

  test "a new file shows its path, and its content folded" do
    html = tool("Write", %{"file_path" => "/w/novo.ex", "content" => "defmodule Novo"})
    assert html =~ "/w/novo.ex"
    assert html =~ "<details"
    assert html =~ "defmodule Novo"
  end

  test "reads and searches take one line" do
    assert tool("Read", %{"file_path" => "/w/lib/a.ex"}) =~ "/w/lib/a.ex"
    html = tool("Grep", %{"pattern" => "def login", "path" => "lib"})
    assert html =~ "def login"
    assert html =~ "lib"
  end

  test "the task list shows each item's state" do
    html =
      tool("TodoWrite", %{
        "todos" => [
          %{"content" => "Reproduzir", "status" => "completed"},
          %{"content" => "Corrigir", "status" => "in_progress"}
        ]
      })

    assert html =~ ~r/data-status="completed"[^>]*>.*Reproduzir/s
    assert html =~ ~r/data-status="in_progress"[^>]*>.*Corrigir/s
  end

  test "an unknown tool shows its summary" do
    assert render_event("tool_use", %{"name" => "Odd", "text" => "%{n: 1}"}) =~ "%{n: 1}"
  end

  test "a tool's output is folded, with its size; an error is open" do
    html = render_event("tool_result", %{"text" => "1\n2\n3", "is_error" => false})
    assert html =~ "<details"
    refute html =~ ~r/<details[^>]* open/
    assert html =~ "3 linhas"

    assert render_event("tool_result", %{"text" => "boom", "is_error" => true}) =~
             ~r/<details[^>]* open/
  end

  test "the first event of a turn shows its tokens" do
    html =
      render_event("assistant_text", %{
        "text" => "oi",
        "usage" => %{"input" => 12_345, "output" => 678}
      })

    assert html =~ "12.3k → 678 tokens"
  end

  defp ev(seq, type, data), do: %Event{id: seq, seq: seq, type: type, data: data}

  test "steps group consecutive reads and searches, and filter by kind" do
    events = [
      ev(1, "system", %{"text" => "Sessão"}),
      ev(2, "tool_use", %{"name" => "Read", "text" => "a.ex"}),
      ev(3, "tool_result", %{"text" => "...", "is_error" => false}),
      ev(4, "tool_use", %{"name" => "Grep", "text" => "def x"}),
      ev(5, "tool_result", %{"text" => "...", "is_error" => false}),
      ev(6, "tool_use", %{"name" => "Read", "text" => "b.ex"}),
      ev(7, "tool_result", %{"text" => "...", "is_error" => false}),
      ev(8, "assistant_text", %{"text" => "Achei"}),
      ev(9, "tool_use", %{"name" => "Bash", "text" => "mix test"}),
      ev(10, "tool_result", %{"text" => "falhou", "is_error" => true})
    ]

    assert [
             {:event, %{seq: 1}},
             {:group, "Leu 2 arquivos e fez 1 busca", [_, _, _, _, _, _]},
             {:event, %{seq: 8}},
             {:event, %{seq: 9}},
             {:event, %{seq: 10}}
           ] = JobComponents.timeline_items(events, "all")

    assert [{:event, %{seq: 1}}, {:event, %{seq: 8}}] =
             JobComponents.timeline_items(events, "agent")

    assert [{:event, %{seq: 10}}] = JobComponents.timeline_items(events, "errors")

    assert [{:group, _, _}, {:event, %{seq: 9}}, {:event, %{seq: 10}}] =
             JobComponents.timeline_items(events, "tools")
  end

  describe "what a run reports for auditing" do
    test "thinking is folded with how long it took; hidden thinking says so" do
      html = render_event("thinking", %{"text" => "Ler o arquivo antes.", "duration_ms" => 1_500})
      assert html =~ "Pensou"
      assert html =~ "1 s"
      assert html =~ "Ler o arquivo antes."
      assert render_event("thinking", %{"text" => "", "duration_ms" => 300}) =~ "não mostra"
    end

    test "the end of the run shows its total tokens" do
      html =
        render_event("result", %{
          "text" => "feito",
          "usage" => %{
            "fresh_input" => 7,
            "cache_read" => 2_200,
            "cache_creation" => 200,
            "output" => 33
          }
        })

      assert html =~ "2.4k → 33 tokens"
    end

    test "API retries, compactions, denied permissions and the account's limits" do
      assert render_event("api_retry", %{"text" => "Tentativa 2 de 10 da API: overloaded"}) =~
               "Nova tentativa da API"

      assert render_event("compact", %{
               "text" => "Conversa compactada (auto)",
               "pre_tokens" => 150_000
             }) =~
               "150.0k tokens"

      assert render_event("permission_denied", %{"tool_name" => "Bash", "text" => "rm"}) =~
               "Permissão negada"

      html =
        render_event("rate_limit", %{
          "status" => "allowed",
          "utilization" => %{"five_hour" => 0.2}
        })

      assert html =~ "Limites da conta"
      assert html =~ "five_hour 20%"
    end

    test "a subagent's call is indented and a refused tool says so" do
      html =
        render_event("tool_use", %{"name" => "Bash", "text" => "ls", "parent_tool_use_id" => "t"})

      assert html =~ "subagente"
      assert html =~ "ml-8"

      html =
        render_event("tool_result", %{
          "text" => "negado",
          "is_error" => true,
          "decision" => %{"decision" => "reject", "source" => "config"}
        })

      assert html =~ "negada (config)"
    end

    test "the reasoning filter shows the thinking; errors include retries and denials" do
      events =
        for {type, seq} <-
              Enum.with_index(~w(thinking api_retry permission_denied assistant_text), 1),
            do: %Event{id: seq, seq: seq, type: type, data: %{}}

      assert [{:event, %{type: "thinking"}}] = JobComponents.timeline_items(events, "thinking")

      assert [{:event, %{type: "api_retry"}}, {:event, %{type: "permission_denied"}}] =
               JobComponents.timeline_items(events, "errors")
    end
  end
end
