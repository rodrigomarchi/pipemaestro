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
end
