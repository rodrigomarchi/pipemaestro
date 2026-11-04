defmodule PipeMaestroWeb.JobComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Jobs.Event
  alias PipeMaestroWeb.JobComponents

  @icon_types ~w(system thinking tool_use tool_result rate_limit api_retry compact permission_denied)

  defp ev(seq, type, data \\ %{}), do: %Event{id: seq, seq: seq, type: type, data: data}

  defp render_timeline(events, filter \\ "all", id \\ "tl") do
    render_component(&JobComponents.timeline/1,
      id: id,
      segments: JobComponents.timeline_items(events, filter)
    )
  end

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp one!(html, selector) do
    node = find(html, selector)
    assert Enum.count(node) == 1, "expected one #{selector} in:\n#{html}"
    node
  end

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  # The panel of a single event: its full content, as the click opens it.
  defp panel(type, data) do
    [ev(1, type, data)] |> render_timeline() |> one!("[data-testid=job-event-panel-1]")
  end

  defp panel_html(type, data), do: type |> panel(data) |> LazyHTML.to_html()

  defp tool_panel(name, input), do: panel_html("tool_use", %{"name" => name, "input" => input})

  describe "which events become icons" do
    test "every event without text to read is an icon; the agent's text and the result are not" do
      for type <- @icon_types ++ ["something_new"], do: assert(JobComponents.icon?(ev(1, type)))

      refute JobComponents.icon?(ev(1, "assistant_text", %{"text" => "oi"}))
      refute JobComponents.icon?(ev(1, "result", %{"text" => "feito"}))
    end

    test "a failed tool and an API retry are errors; a refusal is denied; the rest is normal" do
      assert JobComponents.event_state(ev(1, "tool_result", %{"is_error" => true})) == :error
      assert JobComponents.event_state(ev(1, "api_retry", %{"text" => "x"})) == :error
      assert JobComponents.event_state(ev(1, "permission_denied", %{"text" => "rm"})) == :denied

      for type <- ~w(tool_use tool_result) do
        rejected = ev(1, type, %{"decision" => %{"decision" => "reject", "source" => "config"}})
        assert JobComponents.event_state(rejected) == :denied
      end

      for type <- ~w(system thinking tool_use rate_limit compact),
          do: assert(JobComponents.event_state(ev(1, type)) == :normal)

      assert JobComponents.event_state(ev(1, "tool_result", %{"is_error" => false})) == :normal
    end
  end

  describe "the one-line summary of an icon" do
    test "a tool says what it does: a command's purpose, a path, a pattern" do
      summary = fn name, input ->
        JobComponents.event_summary(ev(1, "tool_use", %{"name" => name, "input" => input}))
      end

      assert summary.("Bash", %{"command" => "mix test", "description" => "Roda a suíte"}) ==
               "Bash · Roda a suíte"

      assert summary.("Bash", %{"command" => "mix test\nmix credo"}) == "Bash · mix test"

      long = summary.("Bash", %{"command" => String.duplicate("a", 200)})
      assert long =~ "Bash · aaa"
      assert String.ends_with?(long, "…")
      assert String.length(long) < 100

      assert summary.("Read", %{"file_path" => "/w/lib/a.ex"}) == "Read · /w/lib/a.ex"
      assert summary.("Edit", %{"file_path" => "/w/lib/b.ex"}) == "Edit · /w/lib/b.ex"
      assert summary.("Write", %{"file_path" => "/w/novo.ex"}) == "Write · /w/novo.ex"
      assert summary.("Grep", %{"pattern" => "def login", "path" => "lib"}) == "Grep · def login"
      assert summary.("Glob", %{"pattern" => "**/*.ex"}) == "Glob · **/*.ex"

      assert JobComponents.event_summary(
               ev(1, "tool_use", %{"name" => "Odd", "text" => "%{n: 1}"})
             ) ==
               "Odd · %{n: 1}"
    end

    test "a result says its size, or that it failed or was refused" do
      summary = &JobComponents.event_summary(ev(1, "tool_result", &1))

      assert summary.(%{"text" => "1\n2\n3", "is_error" => false}) == "Saída · 3 linhas"
      assert summary.(%{"text" => "boom", "is_error" => true}) == "Erro · 1 linha"

      assert summary.(%{
               "text" => "negado",
               "is_error" => true,
               "decision" => %{"decision" => "reject", "source" => "config"}
             }) == "Negada (config)"
    end

    test "thinking, the session, the limits, compactions, retries and denials" do
      assert JobComponents.event_summary(
               ev(1, "thinking", %{"text" => "x", "duration_ms" => 1_500})
             ) ==
               "Pensou por 1 s"

      assert JobComponents.event_summary(
               ev(1, "system", %{"text" => "Sessão iniciada (haiku)", "auth" => "none"})
             ) == "Sessão iniciada (haiku) · login pessoal"

      assert JobComponents.event_summary(
               ev(1, "system", %{"text" => "Sessão iniciada", "auth" => "ANTHROPIC_API_KEY"})
             ) == "Sessão iniciada · chave de API"

      assert JobComponents.event_summary(
               ev(1, "rate_limit", %{
                 "status" => "allowed",
                 "utilization" => %{"five_hour" => 0.2}
               })
             ) == "allowed · five_hour 20%"

      assert JobComponents.event_summary(
               ev(1, "compact", %{"text" => "Conversa compactada (auto)", "pre_tokens" => 150_000})
             ) == "Conversa compactada (auto) · tinha 150.0k tokens"

      assert JobComponents.event_summary(
               ev(1, "api_retry", %{"text" => "Tentativa 2 de 10 da API: overloaded"})
             ) == "Tentativa 2 de 10 da API: overloaded"

      denied =
        JobComponents.event_summary(
          ev(1, "permission_denied", %{"tool_name" => "Bash", "text" => "rm -rf /"})
        )

      assert denied =~ "Bash"
      assert denied =~ "rm -rf /"
    end

    test "a subagent's event says so; the first event of a turn carries its tokens" do
      assert JobComponents.event_summary(
               ev(1, "tool_use", %{"name" => "Bash", "text" => "ls", "parent_tool_use_id" => "t"})
             ) =~ ~r/ · subagente$/

      assert JobComponents.event_summary(
               ev(1, "thinking", %{
                 "duration_ms" => 1_500,
                 "usage" => %{"input" => 12_345, "output" => 678}
               })
             ) =~ "12.3k → 678 tokens"
    end
  end

  describe "segments" do
    defp run do
      [
        ev(1, "system", %{"text" => "Sessão"}),
        ev(2, "tool_use", %{"name" => "Read", "text" => "a.ex"}),
        ev(3, "tool_result", %{"text" => "...", "is_error" => false}),
        ev(4, "tool_use", %{"name" => "Grep", "text" => "def x"}),
        ev(5, "tool_result", %{"text" => "...", "is_error" => false}),
        ev(6, "tool_use", %{"name" => "Read", "text" => "b.ex"}),
        ev(7, "tool_result", %{"text" => "...", "is_error" => false}),
        ev(8, "assistant_text", %{"text" => "Achei"}),
        ev(9, "tool_use", %{"name" => "Bash", "text" => "mix test"}),
        ev(10, "tool_result", %{"text" => "falhou", "is_error" => true}),
        ev(11, "thinking", %{"duration_ms" => 300}),
        ev(12, "result", %{"text" => "feito"})
      ]
    end

    defp seqs(%{events: events}), do: Enum.map(events, & &1.seq)

    test "consecutive icons share a strip; the agent's text breaks it" do
      assert [
               %{kind: :strip, id: "strip-all-1"} = first,
               %{kind: :text, id: "text-8", events: [%{seq: 8}]},
               %{kind: :strip, id: "strip-all-9"} = second,
               %{kind: :text, id: "text-12", events: [%{seq: 12}]}
             ] = JobComponents.timeline_items(run(), "all")

      assert seqs(first) == Enum.to_list(1..7)
      assert seqs(second) == [9, 10, 11]
    end

    test "each filter applies before the grouping, and names its strips" do
      assert [
               %{kind: :strip, id: "strip-agent-1", events: [%{seq: 1}]},
               %{kind: :text, events: [%{seq: 8}]},
               %{kind: :text, events: [%{seq: 12}]}
             ] = JobComponents.timeline_items(run(), "agent")

      assert [%{kind: :strip, id: "strip-tools-2"} = tools] =
               JobComponents.timeline_items(run(), "tools")

      assert seqs(tools) == [2, 3, 4, 5, 6, 7, 9, 10]

      assert [%{kind: :strip, id: "strip-thinking-11", events: [%{seq: 11}]}] =
               JobComponents.timeline_items(run(), "thinking")

      assert [%{kind: :strip, events: [%{seq: 10}]}] =
               JobComponents.timeline_items(run(), "errors")
    end

    test "the reasoning filter keeps only thinking; errors keep retries and denials" do
      events =
        for {type, seq} <-
              Enum.with_index(~w(thinking api_retry permission_denied assistant_text thinking), 1),
            do: ev(seq, type)

      assert [%{kind: :strip, events: [%{type: "thinking"}, %{type: "thinking"}]}] =
               JobComponents.timeline_items(events, "thinking")

      assert [%{kind: :strip, events: [%{type: "api_retry"}, %{type: "permission_denied"}]}] =
               JobComponents.timeline_items(events, "errors")
    end

    test "an empty run has no segments" do
      assert JobComponents.timeline_items([], "all") == []
    end
  end

  describe "a live run" do
    test "an icon joins the open strip, under the same id; text closes it" do
      tail = JobComponents.timeline_tail([])

      {%{id: "strip-all-1", kind: :strip, events: [%{seq: 1}]}, tail} =
        JobComponents.timeline_push(tail, ev(1, "system", %{"text" => "Sessão"}))

      {%{id: "strip-all-1", kind: :strip} = strip, tail} =
        JobComponents.timeline_push(tail, ev(2, "thinking", %{"duration_ms" => 300}))

      assert Enum.map(strip.events, & &1.seq) == [1, 2]

      {%{id: "text-3", kind: :text, events: [%{seq: 3}]}, tail} =
        JobComponents.timeline_push(tail, ev(3, "assistant_text", %{"text" => "oi"}))

      assert tail.strip == nil

      {%{id: "strip-all-4", kind: :strip, events: [%{seq: 4}]}, _tail} =
        JobComponents.timeline_push(tail, ev(4, "tool_use", %{"name" => "Bash", "text" => "ls"}))
    end

    test "an event already shown is seen, and changes nothing" do
      {_segment, tail} =
        JobComponents.timeline_push(JobComponents.timeline_tail([]), ev(1, "system"))

      assert {:seen, ^tail} = JobComponents.timeline_push(tail, ev(1, "system"))
    end

    test "the run read on mount goes on growing its last strip" do
      tail =
        [ev(1, "assistant_text", %{"text" => "oi"}), ev(2, "thinking"), ev(3, "tool_use")]
        |> JobComponents.timeline_items("all")
        |> JobComponents.timeline_tail()

      assert {:seen, _tail} = JobComponents.timeline_push(tail, ev(3, "tool_use"))

      assert {%{id: "strip-all-2"} = strip, _tail} =
               JobComponents.timeline_push(tail, ev(4, "tool_result", %{"text" => "ok"}))

      assert Enum.map(strip.events, & &1.seq) == [2, 3, 4]
    end

    test "a whole run is the same as pushing its events one by one" do
      {pushed, _tail} =
        Enum.reduce(run(), {[], JobComponents.timeline_tail([])}, fn event, {segments, tail} ->
          {segment, tail} = JobComponents.timeline_push(tail, event)
          {List.keystore(segments, segment.id, 0, {segment.id, segment}), tail}
        end)

      assert Enum.map(pushed, &elem(&1, 1)) == JobComponents.timeline_items(run(), "all")
    end
  end

  describe "a strip of icons" do
    test "one button per event, with its kind, state, label and summary" do
      html =
        render_timeline([
          ev(1, "system", %{"text" => "Sessão iniciada (haiku)", "auth" => "none"}),
          ev(2, "tool_use", %{
            "name" => "Bash",
            "input" => %{"command" => "mix test", "description" => "Roda a suíte"}
          }),
          ev(3, "tool_result", %{"text" => "boom", "is_error" => true}),
          ev(4, "permission_denied", %{"tool_name" => "Bash", "text" => "rm"}),
          ev(5, "assistant_text", %{"text" => "Achei"}),
          ev(6, "thinking", %{"duration_ms" => 1_500})
        ])

      strip = one!(html, "[data-testid=job-event-strip-1]")
      assert strip |> LazyHTML.query("[data-testid^=job-event-icon-]") |> Enum.count() == 4

      bash = one!(html, "[data-testid=job-event-strip-1] button[data-testid=job-event-icon-2]")
      assert attr(bash, "data-type") == "tool_use"
      assert attr(bash, "data-state") == "normal"
      assert attr(bash, "aria-label") == "Ferramenta: Bash · Roda a suíte"
      assert attr(bash, "aria-expanded") == "false"
      refute attr(bash, "class") =~ "danger"
      assert LazyHTML.to_html(strip) =~ "Bash · Roda a suíte"

      error = one!(html, "[data-testid=job-event-icon-3]")
      assert attr(error, "data-state") == "error"
      assert attr(error, "class") =~ "danger"

      denied = one!(html, "[data-testid=job-event-icon-4]")
      assert attr(denied, "data-state") == "denied"
      assert attr(denied, "class") =~ "danger"

      one!(html, "[data-testid=job-event-5][data-type=assistant_text]")
      one!(html, "[data-testid=job-event-strip-6] [data-testid=job-event-icon-6]")
    end

    test "each icon toggles its own panel, rendered hidden below the strip" do
      html =
        render_timeline([
          ev(1, "thinking", %{"text" => "Ler antes.", "duration_ms" => 1_500}),
          ev(2, "tool_use", %{"name" => "Read", "input" => %{"file_path" => "/w/a.ex"}})
        ])

      for seq <- [1, 2] do
        panel = one!(html, "[data-testid=job-event-strip-1] [data-testid=job-event-panel-#{seq}]")
        assert attr(panel, "class") =~ "hidden"
        assert attr(panel, "data-type") in ["thinking", "tool_use"]

        icon = one!(html, "[data-testid=job-event-icon-#{seq}]")
        assert attr(icon, "phx-click") =~ attr(panel, "id")
        assert attr(icon, "phx-click") =~ "tl"
      end
    end

    test "two timelines on a page have their own ids" do
      events = [ev(1, "thinking", %{"duration_ms" => 300})]
      a = events |> render_timeline("all", "a") |> one!("[data-testid=job-event-panel-1]")
      b = events |> render_timeline("all", "b") |> one!("[data-testid=job-event-panel-1]")
      assert attr(a, "id") != attr(b, "id")
    end

    test "an unknown kind of event is an icon named after its kind" do
      icon =
        [ev(1, "something_new", %{"text" => "x"})]
        |> render_timeline()
        |> one!("[data-testid=job-event-icon-1]")

      assert attr(icon, "aria-label") =~ "something_new"
      refute attr(icon, "aria-label") =~ "Fim da execução"
    end

    test "a subagent's icon is marked" do
      html =
        render_timeline([
          ev(1, "tool_use", %{"name" => "Bash", "text" => "ls", "parent_tool_use_id" => "t"}),
          ev(2, "tool_use", %{"name" => "Bash", "text" => "ls"})
        ])

      assert html |> one!("[data-testid=job-event-icon-1]") |> attr("data-subagent")
      refute html |> one!("[data-testid=job-event-icon-2]") |> attr("data-subagent")
      assert html |> one!("[data-testid=job-event-panel-1]") |> LazyHTML.text() =~ "subagente"
    end
  end

  describe "a panel shows the event in full" do
    test "the session says which credential and permission mode it ran with" do
      html =
        panel_html("system", %{
          "text" => "Sessão iniciada (haiku)",
          "auth" => "none",
          "permission_mode" => "dontAsk"
        })

      assert html =~ "login pessoal"
      assert html =~ "dontAsk"
    end

    test "a shell command shows as one, with what it is for" do
      html = tool_panel("Bash", %{"command" => "mix test", "description" => "Roda a suíte"})
      assert html =~ "$ mix test"
      assert html =~ "Roda a suíte"
    end

    test "an edit shows as a diff of the file" do
      html =
        tool_panel("Edit", %{
          "file_path" => "/w/lib/a.ex",
          "old_string" => "a\nb",
          "new_string" => "c"
        })

      assert html =~ "/w/lib/a.ex"
      assert html =~ ~r/class="[^"]*diff-del[^"]*">-a</
      assert html =~ ~r/class="[^"]*diff-del[^"]*">-b</
      assert html =~ ~r/class="[^"]*diff-add[^"]*">\+c</
    end

    test "a new file shows its path, and its content folded" do
      html = tool_panel("Write", %{"file_path" => "/w/novo.ex", "content" => "defmodule Novo"})
      assert html =~ "/w/novo.ex"
      assert html =~ "<details"
      assert html =~ "defmodule Novo"
    end

    test "reads and searches show their arguments" do
      assert tool_panel("Read", %{"file_path" => "/w/lib/a.ex"}) =~ "/w/lib/a.ex"
      html = tool_panel("Grep", %{"pattern" => "def login", "path" => "lib"})
      assert html =~ "def login"
      assert html =~ "lib"
    end

    test "the task list shows each item's state" do
      html =
        tool_panel("TodoWrite", %{
          "todos" => [
            %{"content" => "Reproduzir", "status" => "completed"},
            %{"content" => "Corrigir", "status" => "in_progress"}
          ]
        })

      assert html =~ ~r/data-status="completed"[^>]*>.*Reproduzir/s
      assert html =~ ~r/data-status="in_progress"[^>]*>.*Corrigir/s
    end

    test "an unknown tool shows its summary" do
      assert panel_html("tool_use", %{"name" => "Odd", "text" => "%{n: 1}"}) =~ "%{n: 1}"
    end

    test "a tool's output is open, with its size; an empty one says so" do
      html = panel_html("tool_result", %{"text" => "1\n2\n3", "is_error" => false})
      refute html =~ "<details"
      assert html =~ "3 linhas"
      assert html =~ "1\n2\n3"

      error = panel_html("tool_result", %{"text" => "boom", "is_error" => true})
      refute error =~ "<details"
      assert error =~ "boom"
      assert error =~ "Erro da ferramenta"

      assert panel_html("tool_result", %{"text" => "", "is_error" => false}) =~ "Sem saída."
    end

    test "a refused tool says so" do
      html =
        panel_html("tool_result", %{
          "text" => "negado",
          "is_error" => true,
          "decision" => %{"decision" => "reject", "source" => "config"}
        })

      assert html =~ "negada (config)"
    end

    test "thinking is open with how long it took; hidden thinking says so" do
      html = panel_html("thinking", %{"text" => "Ler o arquivo antes.", "duration_ms" => 1_500})
      refute html =~ "<details"
      assert html =~ "Pensou"
      assert html =~ "1 s"
      assert html =~ "Ler o arquivo antes."
      assert panel_html("thinking", %{"text" => "", "duration_ms" => 300}) =~ "não mostra"
    end

    test "API retries, compactions, denied permissions and the account's limits" do
      assert panel_html("api_retry", %{"text" => "Tentativa 2 de 10 da API: overloaded"}) =~
               "Nova tentativa da API"

      assert panel_html("compact", %{
               "text" => "Conversa compactada (auto)",
               "pre_tokens" => 150_000
             }) =~ "150.0k tokens"

      assert panel_html("permission_denied", %{"tool_name" => "Bash", "text" => "rm"}) =~
               "Permissão negada"

      html =
        panel_html("rate_limit", %{
          "status" => "allowed",
          "utilization" => %{"five_hour" => 0.2}
        })

      assert html =~ "Limites da conta"
      assert html =~ "five_hour 20%"
    end

    test "the first event of a turn shows its tokens" do
      assert panel_html("thinking", %{
               "duration_ms" => 300,
               "usage" => %{"input" => 12_345, "output" => 678}
             }) =~ "12.3k → 678 tokens"
    end
  end

  describe "a text block" do
    defp text_block(seq, type, data) do
      [ev(seq, type, data)]
      |> render_timeline()
      |> one!("[data-testid=job-event-#{seq}][data-type=#{type}]")
      |> LazyHTML.to_html()
    end

    test "the agent's text is rendered Markdown, with its tokens" do
      html =
        text_block(1, "assistant_text", %{
          "text" => "Achei o **bug** em `login.ex`",
          "usage" => %{"input" => 12_345, "output" => 678}
        })

      assert html =~ "<strong>bug</strong>"
      assert html =~ "<code>login.ex</code>"
      assert html =~ "12.3k → 678 tokens"
    end

    test "the end of the run shows its total tokens" do
      html =
        text_block(1, "result", %{
          "text" => "feito",
          "usage" => %{
            "fresh_input" => 7,
            "cache_read" => 2_200,
            "cache_creation" => 200,
            "output" => 33
          }
        })

      assert html =~ "feito"
      assert html =~ "2.4k → 33 tokens"
    end

    test "a subagent's text is indented" do
      html = text_block(1, "assistant_text", %{"text" => "oi", "parent_tool_use_id" => "t"})
      assert html =~ "subagente"
      assert html =~ "ml-8"
    end
  end

  test "a finished run's steps are strips and text blocks, without groups of reads" do
    html =
      render_component(&JobComponents.steps/1,
        id: "a-1",
        items:
          JobComponents.timeline_items(
            [
              ev(1, "tool_use", %{"name" => "Read", "text" => "a.ex"}),
              ev(2, "tool_use", %{"name" => "Read", "text" => "b.ex"}),
              ev(3, "assistant_text", %{"text" => "Achei"})
            ],
            "all"
          )
      )

    steps = one!(html, "[data-testid=stage-run-steps-a-1]")
    assert steps |> LazyHTML.query("[data-testid=job-event-strip-1]") |> Enum.count() == 1
    assert steps |> LazyHTML.query("[data-testid=job-event-3]") |> Enum.count() == 1
    refute html =~ "job-event-group"
    refute html =~ "Leu 2 arquivos"
  end
end
