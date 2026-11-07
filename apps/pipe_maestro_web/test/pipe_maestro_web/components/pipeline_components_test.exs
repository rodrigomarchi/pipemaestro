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

    test "a parallel step forks to and joins from each of its stages" do
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
      assert count(html, "[data-testid=diagram-fork-1] path") == 3
      assert count(html, "[data-testid=diagram-join-1] path") == 3
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
      assert count(html, "[data-testid=diagram-left-0][disabled]") == 1
      assert count(html, "[data-testid=diagram-right-3][disabled]") == 1
      assert count(html, "[data-testid=diagram-remove-1][phx-click=remove_stage]") == 1
      # The first stage prepares the worktree and never runs in a group, so
      # neither it nor the one after it can join the one before.
      assert count(html, "[data-testid=diagram-join-group-0]") == 0
      assert count(html, "[data-testid=diagram-join-group-1]") == 0
      assert count(html, "[data-testid=diagram-join-group-2][phx-click=join_group]") == 1
      assert count(html, "[data-testid=diagram-leave-group-3][phx-click=leave_group]") == 1
    end

    test "compact mode is a small, inert preview" do
      html = render_diagram(diagram([stage("a"), stage("b")]), mode: :compact)

      assert text(html, "[data-testid=diagram-stage-1]") =~ "b"
      assert count(html, "[phx-click]") == 0
      assert count(html, "[data-testid=diagram-rail]") == 0
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
  end

  describe "delivery_label/1" do
    test "names each delivery" do
      assert PipelineComponents.delivery_label("pr") == "Pull request"
      assert PipelineComponents.delivery_label("commit") == "Commits conferidos"
      assert PipelineComponents.delivery_label("none") == "Sem entrega"
      assert PipelineComponents.delivery_icon("pr") == "hero-rocket-launch"
    end
  end
end
