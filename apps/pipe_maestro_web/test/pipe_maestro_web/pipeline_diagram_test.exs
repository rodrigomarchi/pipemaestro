defmodule PipeMaestroWeb.PipelineDiagramTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Pipelines.{Pipeline, Stage}
  alias PipeMaestroWeb.PipelineDiagram

  defp stage(name, attrs \\ []), do: struct(%Stage{name: name, key: name, prompt: "p"}, attrs)

  defp pipeline(stages, attrs \\ []), do: struct(%Pipeline{stages: stages}, attrs)

  describe "build/1" do
    test "a linear pipeline is one step per stage, in order" do
      diagram = PipelineDiagram.build(pipeline([stage("a"), stage("b"), stage("c")]))

      assert [%{parallel?: false, nodes: [%{index: 0, name: "a"}]}, %{nodes: [%{index: 1}]}, _c] =
               diagram.steps
    end

    test "consecutive stages of a group are one parallel step" do
      diagram =
        PipelineDiagram.build(
          pipeline([stage("a"), stage("b", group: "r"), stage("c", group: "r"), stage("d")])
        )

      assert [
               %{parallel?: false},
               %{parallel?: true, group: "r", nodes: [%{index: 1}, %{index: 2}]},
               %{nodes: [%{index: 3}]}
             ] = diagram.steps
    end

    test "a stage without a name is shown as a new stage" do
      assert %{steps: [%{nodes: [%{name: "Nova etapa"}]}]} =
               PipelineDiagram.build(pipeline([%Stage{}]))
    end

    test "a pipeline without stages has no steps" do
      assert %{steps: []} = PipelineDiagram.build(pipeline([]))
    end

    test "a node carries its attempts, model, timeout and gate count" do
      gates = [%{"command" => "mix test", "expect" => "pass"}]

      assert %{steps: [%{nodes: [node]}]} =
               PipelineDiagram.build(
                 pipeline([
                   stage("a", max_attempts: 3, model: "opus", timeout_minutes: 30, gates: gates)
                 ])
               )

      assert %{attempts: 3, model: "opus", timeout_minutes: 30, gates: 1} = node
    end

    test "a node's chips leave out what the node shows apart: attempts, the default model" do
      assert %{steps: [%{nodes: [plain]}, %{nodes: [opus]}]} =
               PipelineDiagram.build(pipeline([stage("a"), stage("b", model: "opus")]))

      assert plain.chips == [{"hero-clock", "60 min"}]
      assert opus.chips == [{"hero-sparkles", "opus"}, {"hero-clock", "60 min"}]
    end

    test "the entry lists the pipeline's context" do
      diagram =
        PipelineDiagram.build(
          pipeline([stage("a")],
            name: "Bug",
            system_prompt: "seja breve",
            mcp_config: %{"mcpServers" => %{"grafana" => %{}}},
            agents: %{"revisor" => %{}}
          )
        )

      assert diagram.entry == %{
               name: "Bug",
               system_prompt?: true,
               mcp_servers: ["grafana"],
               agents: ["revisor"]
             }
    end
  end

  describe "delivery" do
    test "none: no stage delivers and there is no delivery node" do
      diagram = PipelineDiagram.build(pipeline([stage("a")], delivery: "none"))

      assert diagram.delivery == :none
      assert [%{nodes: [%{delivers?: false}]}] = diagram.steps
    end

    test "commit or pr: every stage outside a group delivers, with the platform checks" do
      for delivery <- ~w(commit pr) do
        diagram =
          PipelineDiagram.build(
            pipeline([stage("a"), stage("b", group: "r"), stage("c", group: "r")],
              delivery: delivery
            )
          )

        assert diagram.delivery == String.to_atom(delivery)

        assert [
                 %{nodes: [%{delivers?: true}]},
                 %{nodes: [%{delivers?: false}, %{delivers?: false}]}
               ] =
                 diagram.steps
      end
    end
  end

  describe "the decision rail" do
    test "every stage fails to a person, and each rule pauses for one" do
      rules = [%{"field" => "risco", "op" => "==", "value" => "alto"}]
      diagram = PipelineDiagram.build(pipeline([stage("a"), stage("b", rules: rules)]))

      assert diagram.rail.edges == [
               %{index: 0, kind: :failure, label: "esgotou ou bloqueou", active?: false},
               %{index: 1, kind: :failure, label: "esgotou ou bloqueou", active?: false},
               %{index: 1, kind: :rule, label: "risco == alto", active?: false}
             ]
    end

    test "the cost cap pauses the task too" do
      diagram =
        PipelineDiagram.build(pipeline([stage("a")], max_task_cost_usd: Decimal.new("5.00")))

      assert diagram.rail.cost_cap == "US$ 5.00"
      assert PipelineDiagram.build(pipeline([stage("a")])).rail.cost_cap == nil
    end
  end

  describe "chips/1" do
    test "says what a stage is, in short" do
      stage =
        stage("a",
          model: "opus",
          max_attempts: 1,
          timeout_minutes: 15,
          gates: [
            %{"command" => "x", "expect" => "pass"},
            %{"command" => "y", "expect" => "fail"}
          ],
          rules: [%{"field" => "f", "op" => "==", "value" => "v"}],
          group: "r",
          agent: "revisor"
        )

      assert PipelineDiagram.chips(stage) == [
               {"hero-sparkles", "opus"},
               {"hero-arrow-path", "1 tentativa"},
               {"hero-clock", "15 min"},
               {"hero-shield-check", "2 gates"},
               {"hero-hand-raised", "1 regra de ajuda"},
               {"hero-squares-2x2", "grupo r"},
               {"hero-user-circle", "revisor"}
             ]
    end

    test "a plain stage has the defaults" do
      assert PipelineDiagram.chips(%Stage{}) == [
               {"hero-sparkles", "modelo padrão"},
               {"hero-arrow-path", "2 tentativas"},
               {"hero-clock", "60 min"}
             ]
    end
  end

  describe "build/2 with a task's states" do
    test "each node takes its state; the rail lights the edges of a node that waits" do
      rules = [%{"field" => "risco", "op" => "==", "value" => "alto"}]

      diagram =
        PipelineDiagram.build(pipeline([stage("a"), stage("b", rules: rules), stage("c")]),
          states: %{0 => :passed, 1 => :awaiting}
        )

      assert [[%{state: :passed}], [%{state: :awaiting}], [%{state: :pending}]] =
               Enum.map(diagram.steps, & &1.nodes)

      assert [
               %{index: 0, active?: false},
               %{index: 1, active?: true},
               %{index: 1, active?: true} | _
             ] =
               diagram.rail.edges

      assert diagram.waiting? == true
    end

    test "without states, nodes have none and nothing is lit" do
      diagram = PipelineDiagram.build(pipeline([stage("a")]))
      assert [%{nodes: [%{state: nil}]}] = diagram.steps
      assert diagram.waiting? == false
    end
  end

  describe "build/2 with metrics" do
    test "a node shows the metrics given for it" do
      diagram =
        PipelineDiagram.build(pipeline([stage("a"), stage("b")]),
          metrics: %{1 => [{"hero-banknotes", "US$ 1.20"}]}
        )

      assert [[%{metrics: []}], [%{metrics: [{"hero-banknotes", "US$ 1.20"}]}]] =
               Enum.map(diagram.steps, & &1.nodes)
    end
  end

  describe "build/2 compared to another version" do
    test "marks the stages added and changed, and names the ones removed" do
      before = pipeline([stage("a"), stage("b"), stage("gone")])
      revised = pipeline([stage("a"), stage("b", prompt: "outro"), stage("new")])

      diagram = PipelineDiagram.build(revised, compare_to: before)

      assert [[%{diff: nil}], [%{diff: :changed}], [%{diff: :added}]] =
               Enum.map(diagram.steps, & &1.nodes)

      assert diagram.removed == ["gone"]
    end
  end

  describe "for_task/1 and task_states/1" do
    alias PipeMaestro.Tasks.{StageRun, Task}

    defp task(attrs) do
      struct(
        %Task{
          pipeline_name: "Bug",
          stages: [stage("a"), stage("b"), stage("c")],
          pipeline_context: %{
            "delivery" => "pr",
            "max_cost_usd" => "5.00",
            "system_prompt" => "x"
          },
          current_stage: 0,
          status: :running,
          stage_runs: []
        },
        attrs
      )
    end

    test "the pipeline a task runs: its snapshot of stages and context" do
      pipeline = PipelineDiagram.for_task(task([]))

      assert %Pipeline{name: "Bug", delivery: "pr", system_prompt: "x"} = pipeline
      assert Decimal.equal?(pipeline.max_task_cost_usd, Decimal.new("5.00"))
      assert length(pipeline.stages) == 3
    end

    test "each stage's state: its last attempt, waiting where the task waits, or pending" do
      runs = [
        %StageRun{index: 0, attempt: 1, status: :failed},
        %StageRun{index: 0, attempt: 2, status: :passed},
        %StageRun{index: 1, attempt: 1, status: :blocked}
      ]

      assert PipelineDiagram.task_states(task(stage_runs: runs, current_stage: 1)) ==
               %{0 => :passed, 1 => :blocked, 2 => :pending}

      assert PipelineDiagram.task_states(
               task(stage_runs: runs, current_stage: 1, status: :awaiting_decision)
             ) == %{0 => :passed, 1 => :awaiting, 2 => :pending}
    end
  end
end
