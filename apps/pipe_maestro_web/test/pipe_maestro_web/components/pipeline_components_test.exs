defmodule PipeMaestroWeb.PipelineComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PipeMaestro.Pipelines.{Pipeline, Stage}
  alias PipeMaestroWeb.{PipelineComponents, PipelineDiagram}

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> find(selector) |> Enum.count()
  defp text(html, selector), do: html |> find(selector) |> LazyHTML.text()

  defp stage(name, attrs \\ []), do: struct(%Stage{name: name, key: name, prompt: "p"}, attrs)

  defp diagram(stages, attrs \\ []),
    do: PipelineDiagram.build(struct(%Pipeline{name: "Bug", stages: stages}, attrs))

  defp render_diagram(diagram, attrs \\ []),
    do: render_component(&PipelineComponents.pipeline_diagram/1, [diagram: diagram] ++ attrs)

  describe "pipeline_diagram/1" do
    test "draws the entry, a node per stage and the end" do
      html = render_diagram(diagram([stage("Triagem"), stage("Correção")]))

      assert count(html, "[data-testid=diagram-entry]") == 1
      assert text(html, "[data-testid=diagram-stage-0]") =~ "Triagem"
      assert text(html, "[data-testid=diagram-stage-1]") =~ "Correção"
      assert count(html, "[data-testid=diagram-end]") == 1
    end

    test "draws top to bottom on the rail: entry, a place per step, the end" do
      html = render_diagram(diagram([stage("a"), stage("b")]), mode: :edit)

      assert count(html, "[data-testid=pipeline-diagram] > ol > li [data-testid=diagram-entry]") ==
               1

      assert count(html, "ol > li[data-testid=diagram-step-0] [data-testid=diagram-stage-0]") == 1
      assert count(html, "ol > li[data-testid=diagram-step-1] [data-testid=diagram-stage-1]") == 1
      assert count(html, "ol > li [data-testid=diagram-end]") == 1
      # Nothing scrolls sideways: the diagram fits a phone.
      assert count(html, ".overflow-x-auto") == 0
    end

    test "a parallel step puts its stages side by side, each with its number" do
      html =
        render_diagram(
          diagram([
            stage("a"),
            stage("b", group: "r"),
            stage("c", group: "r"),
            stage("d", group: "r")
          ])
        )

      assert count(html, "[data-testid=diagram-step-1][data-parallel]") == 1
      assert text(html, "[data-testid=diagram-group-1]") =~ "Em paralelo · r"
      assert count(html, "[data-testid=diagram-step-1] [data-testid^=diagram-stage-]") == 3
      assert count(html, "[data-testid=diagram-step-0][data-parallel]") == 0
    end

    test "each stage says where it stops for a person" do
      html =
        render_diagram(
          diagram([
            stage("a"),
            stage("b", rules: [%{"field" => "risco", "op" => "==", "value" => "alto"}])
          ])
        )

      assert text(html, "[data-testid=diagram-edge-0-failure]") =~ "esgotou ou bloqueou"
      assert count(html, "[data-testid=diagram-rules-0]") == 0
      assert text(html, "[data-testid=diagram-rules-1]") =~ "Pede ajuda quando"
      assert count(html, "[data-testid=diagram-rules-1] [data-testid=diagram-edge-1-rule-0]") == 1
    end

    test "a node shows its attempts loop" do
      html = render_diagram(diagram([stage("a", max_attempts: 3)]))
      assert text(html, "[data-testid=diagram-attempts-0]") =~ "3"
    end

    test "the rail takes each stage's failure and rules, and the cost cap" do
      rules = [%{"field" => "risco", "op" => "==", "value" => "alto"}]

      html =
        render_diagram(
          diagram([stage("a"), stage("b", rules: rules)], max_task_cost_usd: Decimal.new("5"))
        )

      assert count(html, "[data-testid=diagram-rail]") == 1
      assert count(html, "[data-testid=diagram-edge-0-failure]") == 1
      assert count(html, "[data-testid=diagram-edge-1-failure]") == 1
      assert text(html, "[data-testid=diagram-edge-1-rule-0]") =~ "risco == alto"
      assert text(html, "[data-testid=diagram-cost-cap]") =~ "US$ 5"
    end

    test "a pull request delivery ends in a delivery node; commits mark each stage" do
      pr = render_diagram(diagram([stage("a")], delivery: "pr"))
      assert text(pr, "[data-testid=diagram-delivery]") =~ "Pull request"
      assert count(pr, "[data-testid=diagram-delivers-0]") == 1

      commit = render_diagram(diagram([stage("a")], delivery: "commit"))
      assert count(commit, "[data-testid=diagram-delivery]") == 0
      assert count(commit, "[data-testid=diagram-delivers-0]") == 1

      none = render_diagram(diagram([stage("a")], delivery: "none"))
      assert count(none, "[data-testid=diagram-delivery]") == 0
      assert count(none, "[data-testid=diagram-delivers-0]") == 0
    end

    test "the selected node is marked" do
      html = render_diagram(diagram([stage("a"), stage("b")]), selected: {:stage, 1})

      assert count(html, "[data-testid=diagram-stage-1] [aria-pressed=true]") == 1
      assert count(html, "[data-testid=diagram-stage-0] [aria-pressed=false]") == 1
    end

    test "read mode selects but does not change the structure" do
      html = render_diagram(diagram([stage("a"), stage("b")]))

      assert count(html, "[phx-click=select_node]") == 3
      assert count(html, "[data-testid^=diagram-insert-]") == 0
      assert count(html, "[data-testid^=diagram-remove-]") == 0
    end

    test "edit mode inserts between steps, moves, removes and groups" do
      html =
        render_diagram(
          diagram([stage("a"), stage("b"), stage("c"), stage("d", group: "r")]),
          mode: :edit
        )

      for at <- 0..4, do: assert(count(html, "[data-testid=diagram-insert-#{at}]") == 1)
      assert count(html, "[data-testid=diagram-insert-4][phx-click=insert_stage]") == 1
      assert count(html, "[data-testid=diagram-up-0][disabled]") == 1
      assert count(html, "[data-testid=diagram-down-3][disabled]") == 1
      assert text(html, "[data-testid=diagram-insert-4]") =~ "Adicionar etapa"
      assert count(html, "[data-testid=diagram-remove-1][phx-click=remove_stage]") == 1
      # The first stage prepares the worktree and never runs in a group, so
      # neither it nor the one after it can join the one before.
      assert count(html, "[data-testid=diagram-join-group-0]") == 0
      assert count(html, "[data-testid=diagram-join-group-1]") == 0
      assert count(html, "[data-testid=diagram-join-group-2][phx-click=join_group]") == 1
      assert count(html, "[data-testid=diagram-leave-group-3][phx-click=leave_group]") == 1
    end

    test "compact mode is a small, inert preview: a numbered mark per stage" do
      html = render_diagram(diagram([stage("a"), stage("b")]), mode: :compact)

      assert text(html, "[data-testid=diagram-stage-1]") =~ "2"
      assert count(html, "[data-testid=diagram-stage-1][title='2. b']") == 1
      assert count(html, "[phx-click]") == 0
      assert count(html, "[data-testid=diagram-rail]") == 0
      assert count(html, ".truncate") == 0
    end

    test "compact mode stacks the stages of a parallel step" do
      html =
        render_diagram(
          diagram([stage("a"), stage("b", group: "r"), stage("c", group: "r")]),
          mode: :compact
        )

      assert count(html, "[data-testid=diagram-step-1][data-parallel]") == 1
      assert count(html, "[data-testid=diagram-step-1] [data-testid^=diagram-stage-]") == 2
    end
  end

  describe "stage_chips/1" do
    test "a chip per fact" do
      html =
        render_component(&PipelineComponents.stage_chips/1,
          chips: PipelineDiagram.chips(stage("a", model: "opus")),
          testid: "chips"
        )

      assert text(html, "[data-testid=chips]") =~ "opus"
      assert count(html, "[data-testid=chips] > span") == 3
    end
  end

  describe "stage_details/1" do
    test "says everything about a stage, read-only" do
      html =
        render_component(&PipelineComponents.stage_details/1,
          stage:
            stage("Correção",
              prompt: "Corrija **o bug**",
              gates: [
                %{"command" => "mix test", "expect" => "pass"},
                %{"command" => "mix repro", "expect" => "fail"}
              ],
              rules: [%{"field" => "risco", "op" => "==", "value" => "alto"}],
              output_schema: %{"type" => "object", "properties" => %{}}
            )
        )

      assert html =~ "<strong>o bug</strong>"
      assert text(html, "[data-testid=stage-details-gates]") =~ "mix test"
      assert text(html, "[data-testid=stage-details-gates]") =~ "! mix repro"
      assert text(html, "[data-testid=stage-details-rules]") =~ "risco == alto"
      assert text(html, "[data-testid=stage-details-schema]") =~ "properties"
      assert count(html, "input, textarea, select") == 0
      # The prompt shows; how it is checked and its output are a tab away.
      assert count(html, "[data-testid=stage-details-panel-prompt].hidden") == 0
      assert count(html, "[data-testid=stage-details-panel-verificacao].hidden") == 1
      assert count(html, "[data-testid=stage-details-tab-avancado]") == 1
    end

    test "a stage with only a prompt has no tabs" do
      html = render_component(&PipelineComponents.stage_details/1, stage: stage("Só prompt"))

      assert count(html, "[data-testid=stage-details-tabs]") == 0
      assert count(html, "[data-testid=stage-details-panel-verificacao]") == 1
    end
  end

  describe "pipeline_summary/1" do
    test "the pipeline's context, delivery and cost cap" do
      html =
        render_component(&PipelineComponents.pipeline_summary/1,
          pipeline: %Pipeline{
            name: "Bug",
            description: "Corrige bugs",
            delivery: "pr",
            max_task_cost_usd: Decimal.new("5"),
            system_prompt: "Seja breve",
            mcp_config: %{"mcpServers" => %{"grafana" => %{}}},
            agents: %{"revisor" => %{}}
          }
        )

      assert html =~ "Corrige bugs"
      assert text(html, "[data-testid=pipeline-summary-delivery]") =~ "Pull request"
      assert text(html, "[data-testid=pipeline-summary-cost]") =~ "US$ 5"
      assert html =~ "Seja breve"
      assert text(html, "[data-testid=pipeline-summary-mcp]") =~ "grafana"
      assert text(html, "[data-testid=pipeline-summary-agents]") =~ "revisor"
      assert count(html, "[data-testid=pipeline-summary-panel-avancado].hidden") == 1
    end

    test "says when the automatic analysis of failures is off, and only then" do
      on = %Pipeline{name: "Bug", delivery: "none"}
      off = struct(on, auto_analysis: false)

      html = render_component(&PipelineComponents.pipeline_summary/1, pipeline: on)
      assert count(html, "[data-testid=pipeline-summary-no-analysis]") == 0

      html = render_component(&PipelineComponents.pipeline_summary/1, pipeline: off)
      assert text(html, "[data-testid=pipeline-summary-no-analysis]") =~ "análise"
    end
  end

  describe "side_panel/1" do
    test "stays in the page when closed, hidden" do
      closed =
        render_component(&PipelineComponents.side_panel/1,
          id: "p",
          title: "Etapa",
          open: false,
          inner_block: [%{inner_block: fn _, _ -> "corpo" end}]
        )

      assert count(closed, "#p.hidden") == 1
      assert closed =~ "corpo"

      open =
        render_component(&PipelineComponents.side_panel/1,
          id: "p",
          title: "Etapa",
          open: true,
          inner_block: [%{inner_block: fn _, _ -> "corpo" end}]
        )

      assert count(open, "#p.hidden") == 0
      assert count(open, "#p [phx-click=close_panel]") == 1
      assert text(open, "#p") =~ "Etapa"
    end

    test "is the drawer over a backdrop that closes it" do
      html =
        render_component(&PipelineComponents.side_panel/1,
          id: "p",
          title: "Etapa",
          open: true,
          testid: "p",
          inner_block: [%{inner_block: fn _, _ -> "corpo" end}]
        )

      assert count(html, "#p.lg\\:w-\\[90vw\\]") == 1
      assert count(html, "[data-testid=p-backdrop][phx-click=close_panel]") == 1
      assert count(html, "[data-testid=p-close][phx-click=close_panel]") == 1
      assert text(html, "#p") =~ "corpo"

      closed =
        render_component(&PipelineComponents.side_panel/1,
          id: "p",
          title: "Etapa",
          open: false,
          testid: "p",
          inner_block: [%{inner_block: fn _, _ -> "corpo" end}]
        )

      assert count(closed, "[data-testid=p-backdrop]:not(.hidden)") == 0
    end
  end

  describe "delivery_label/1" do
    test "names each delivery" do
      assert PipelineComponents.delivery_label("pr") == "Pull request"
      assert PipelineComponents.delivery_label("commit") == "Commits conferidos"
      assert PipelineComponents.delivery_label("none") == "Sem entrega"
      assert PipelineComponents.delivery_icon("pr") == "hero-rocket-launch"
    end
  end

  describe "the diagram's layers" do
    test "each node shows a task's state, and a waiting node lights the rail" do
      html =
        render_diagram(
          PipelineDiagram.build(%Pipeline{stages: [stage("a"), stage("b"), stage("c")]},
            states: %{0 => :passed, 1 => :awaiting}
          )
        )

      assert count(html, "[data-testid=diagram-stage-0][data-state=passed]") == 1
      assert text(html, "[data-testid=diagram-state-1]") =~ "Aguardando decisão"
      assert count(html, "[data-testid=diagram-stage-2][data-state=pending]") == 1
      assert count(html, "[data-testid=diagram-edge-1-failure][data-active]") == 1
      assert count(html, "[data-testid=diagram-edge-0-failure][data-active]") == 0
      assert count(html, "[data-testid=diagram-rail][data-waiting]") == 1
    end

    test "metrics show on their node" do
      html =
        render_diagram(
          PipelineDiagram.build(%Pipeline{stages: [stage("a")]},
            metrics: %{0 => [{"hero-banknotes", "US$ 1.20"}]}
          )
        )

      assert text(html, "[data-testid=diagram-metrics-0]") =~ "US$ 1.20"
    end

    test "a comparison marks added and changed stages and names the removed" do
      before = %Pipeline{stages: [stage("a"), stage("b"), stage("x")]}

      html =
        render_diagram(
          PipelineDiagram.build(
            %Pipeline{stages: [stage("a"), stage("b", prompt: "novo"), stage("c")]},
            compare_to: before
          )
        )

      assert count(html, "[data-testid=diagram-diff-0]") == 0
      assert text(html, "[data-testid=diagram-diff-1]") =~ "alterada"
      assert text(html, "[data-testid=diagram-diff-2]") =~ "nova"
      assert text(html, "[data-testid=diagram-removed]") =~ "x"
    end
  end

  describe "micro mode" do
    test "a dot per stage with its state, a group's stacked, nothing to click" do
      html =
        render_diagram(
          PipelineDiagram.build(
            %Pipeline{stages: [stage("a"), stage("b", group: "r"), stage("c", group: "r")]},
            states: %{0 => :passed, 1 => :running}
          ),
          mode: :micro,
          testid: "progress"
        )

      assert count(html, "[data-testid=progress] [data-testid=diagram-dot-0][data-state=passed]") ==
               1

      assert count(html, "[data-testid=diagram-dot-1][data-state=running]") == 1

      assert count(
               html,
               "[data-testid=diagram-step-1][data-parallel] [data-testid^=diagram-dot-]"
             ) == 2

      assert count(
               html,
               "[phx-click], a, [data-testid=diagram-rail], [data-testid=diagram-entry]"
             ) == 0
    end
  end

  describe "stage states" do
    test "a label, a badge and a marker per state" do
      assert PipelineComponents.state_label(:awaiting) == "Aguardando decisão"
      assert PipelineComponents.state_label(:passed) == "Concluída"

      badge = render_component(&PipelineComponents.stage_state_badge/1, state: :failed)
      assert badge =~ "Falhou"

      marker =
        render_component(&PipelineComponents.stage_state_marker/1, state: :pending, number: 3)

      assert marker =~ "3"
    end
  end

  describe "a target for the events" do
    test "the diagram's and the panel's events go to a component, when given one" do
      html = render_diagram(diagram([stage("a")]), target: "#explorer")
      assert count(html, "[phx-click=select_node][phx-target='#explorer']") == 2

      panel =
        render_component(&PipelineComponents.side_panel/1,
          id: "p",
          title: "Etapa",
          open: true,
          target: "#explorer",
          inner_block: [%{inner_block: fn _, _ -> "corpo" end}]
        )

      assert count(panel, "[phx-click=close_panel][phx-target='#explorer']") == 2
    end
  end

  describe "pipeline_preview/1" do
    test "the chosen pipeline, small; nothing before one is chosen" do
      pipelines = [%Pipeline{id: "p1", name: "Bug", stages: [stage("a")]}]

      html =
        render_component(&PipelineComponents.pipeline_preview/1,
          pipelines: pipelines,
          id: "p1",
          testid: "preview"
        )

      assert count(html, "[data-testid=preview] [data-testid=diagram-stage-0]") == 1

      for id <- [nil, "", "other"] do
        html =
          render_component(&PipelineComponents.pipeline_preview/1,
            pipelines: pipelines,
            id: id,
            testid: "preview"
          )

        assert count(html, "[data-testid=preview]") == 0
      end
    end
  end

  describe "the end node" do
    test "is the end, neutral; done only once every stage of a task passed" do
      shape = render_diagram(diagram([stage("a"), stage("b")]))
      assert text(shape, "[data-testid=diagram-end]") =~ "Fim"
      assert count(shape, "[data-testid=diagram-end][data-done]") == 0

      halfway =
        render_diagram(
          PipelineDiagram.build(%Pipeline{stages: [stage("a"), stage("b")]},
            states: %{0 => :passed, 1 => :awaiting}
          )
        )

      assert count(halfway, "[data-testid=diagram-end][data-done]") == 0

      done =
        render_diagram(
          PipelineDiagram.build(%Pipeline{stages: [stage("a"), stage("b")]},
            states: %{0 => :passed, 1 => :passed}
          )
        )

      assert count(done, "[data-testid=diagram-end][data-done]") == 1
    end
  end
end
