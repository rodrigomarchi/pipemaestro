defmodule PipeMaestroWeb.PipelineDiagram do
  @moduledoc """
  A pipeline as a diagram, before it is drawn: the entry with the pipeline's
  context, the steps (`PipeMaestro.Pipelines.steps/1`: a stage alone, or a
  group that runs at once), what is delivered, and the rail of the places a
  task stops for a person: a stage that fails or blocks, a rule that matches,
  the cost cap.

  It reads a `PipeMaestro.Pipelines.Pipeline`: saved, a form's draft or an
  agent's proposal (`Ecto.Changeset.apply_changes/1`), or the snapshot a task
  runs (`for_task/1`). It knows nothing of how it is drawn
  (`PipeMaestroWeb.PipelineComponents.pipeline_diagram/1`).

  Layers over the shape, all optional (`build/2`):

    * `states:` where a task is in each stage (`task_states/1`): a stage that
      waits for a person lights its edges to the rail;
    * `metrics:` facts measured per stage (cost, runs, failures), as chips;
    * `compare_to:` another version of the pipeline: the stages added and
      changed are marked, by key, and the ones removed are named.
  """

  alias PipeMaestro.Pipelines
  alias PipeMaestro.Pipelines.{Pipeline, Stage}
  alias PipeMaestro.Tasks.Task

  @typedoc "One stage, as a node."
  @type stage_node :: %{
          index: non_neg_integer(),
          name: String.t(),
          attempts: pos_integer(),
          model: String.t() | nil,
          timeout_minutes: pos_integer(),
          gates: non_neg_integer(),
          rules: [String.t()],
          agent: String.t() | nil,
          delivers?: boolean(),
          chips: [chip()],
          state: state() | nil,
          metrics: [chip()],
          diff: :added | :changed | nil
        }

  @typedoc "Where a task is in a stage."
  @type state :: :pending | :running | :passed | :failed | :blocked | :awaiting | :canceled

  @typedoc "A short fact about a stage: an icon and a text."
  @type chip :: {String.t(), String.t()}

  @typedoc "A stage alone, or the stages of a group, which run at once."
  @type step :: %{parallel?: boolean(), group: String.t() | nil, nodes: [stage_node()]}

  @typedoc "Where a stage stops the task for a person."
  @type edge :: %{
          index: non_neg_integer(),
          kind: :failure | :rule,
          label: String.t(),
          active?: boolean()
        }

  @type t :: %{
          entry: %{
            name: String.t() | nil,
            system_prompt?: boolean(),
            mcp_servers: [String.t()],
            agents: [String.t()]
          },
          steps: [step()],
          delivery: :none | :commit | :pr,
          rail: %{edges: [edge()], cost_cap: String.t() | nil},
          waiting?: boolean(),
          removed: [String.t()]
        }

  @failure "esgotou ou bloqueou"

  @doc """
  The diagram of a pipeline, with the layers in `opts`: `states`, `metrics`
  (both by stage index) and `compare_to` (a pipeline).
  """
  @spec build(Pipeline.t(), keyword()) :: t()
  def build(%Pipeline{stages: stages} = pipeline, opts \\ []) do
    delivery = delivery(pipeline.delivery)
    states = opts[:states]
    before = opts[:compare_to]

    layers = %{
      state: fn index -> states && Map.get(states, index, :pending) end,
      metrics: fn index -> Map.get(opts[:metrics] || %{}, index, []) end,
      diff: fn stage -> before && diff(stage, before.stages) end
    }

    steps =
      for indexes <- Pipelines.steps(stages) do
        first = Enum.at(stages, hd(indexes))
        parallel? = present?(first.group)

        %{
          parallel?: parallel?,
          group: if(parallel?, do: first.group),
          nodes:
            Enum.map(indexes, &stage_node(Enum.at(stages, &1), &1, delivery, parallel?, layers))
        }
      end

    nodes = Enum.flat_map(steps, & &1.nodes)

    %{
      entry: %{
        name: pipeline.name,
        system_prompt?: present?(pipeline.system_prompt),
        mcp_servers: names(pipeline.mcp_config && pipeline.mcp_config["mcpServers"]),
        agents: names(pipeline.agents)
      },
      steps: steps,
      delivery: delivery,
      rail: %{edges: edges(nodes), cost_cap: cost_cap(pipeline.max_task_cost_usd)},
      waiting?: Enum.any?(nodes, &(&1.state == :awaiting)),
      removed: removed(before, stages)
    }
  end

  @doc """
  The pipeline a task runs: the snapshot of stages and context it kept when it
  started (`PipeMaestro.Pipelines.Pipeline.context/1`), not the pipeline as it
  is now.
  """
  @spec for_task(Task.t()) :: Pipeline.t()
  def for_task(%Task{} = task) do
    context = task.pipeline_context || %{}

    %Pipeline{
      name: task.pipeline_name,
      stages: task.stages,
      delivery: context["delivery"] || "none",
      max_task_cost_usd: context["max_cost_usd"] && Decimal.new(context["max_cost_usd"]),
      system_prompt: context["system_prompt"],
      mcp_config: context["mcp_config"],
      agents: context["agents"]
    }
  end

  @doc """
  Where a task is in each of its stages, by index: the status of the stage's
  last attempt, `:awaiting` where the task waits for a decision, or `:pending`.
  """
  @spec task_states(Task.t()) :: %{non_neg_integer() => state()}
  def task_states(%Task{} = task) do
    last_runs =
      task.stage_runs
      |> Enum.sort_by(& &1.attempt)
      |> Map.new(&{&1.index, &1.status})

    for index <- 0..(length(task.stages) - 1)//1, into: %{} do
      state =
        if task.status == :awaiting_decision and index == task.current_stage,
          do: :awaiting,
          else: Map.get(last_runs, index, :pending)

      {index, state}
    end
  end

  @doc "What a stage is, in short: model, attempts, time limit, gates, rules, group, agent."
  @spec chips(Stage.t()) :: [chip()]
  def chips(%Stage{} = stage) do
    [
      {"hero-sparkles", if(present?(stage.model), do: stage.model, else: "modelo padrão")},
      {"hero-arrow-path", plural(stage.max_attempts || 2, "tentativa", "tentativas")},
      {"hero-clock", "#{stage.timeout_minutes || 60} min"}
    ] ++ optional_chips(stage)
  end

  defp optional_chips(stage) do
    gates = length(stage.gates || [])
    rules = length(stage.rules || [])

    [
      gates > 0 && {"hero-shield-check", plural(gates, "gate", "gates")},
      rules > 0 && {"hero-hand-raised", plural(rules, "regra de ajuda", "regras de ajuda")},
      present?(stage.group) && {"hero-squares-2x2", "grupo #{stage.group}"},
      present?(stage.agent) && {"hero-user-circle", stage.agent}
    ]
    |> Enum.filter(& &1)
  end

  @doc "A stage's rule as a person reads it: `field op value`."
  @spec rule_label(map()) :: String.t()
  def rule_label(rule), do: "#{rule["field"]} #{rule["op"]} #{rule["value"]}"

  defp stage_node(%Stage{} = stage, index, delivery, parallel?, layers) do
    %{
      index: index,
      name: if(present?(stage.name), do: stage.name, else: "Nova etapa"),
      attempts: stage.max_attempts || 2,
      model: stage.model,
      timeout_minutes: stage.timeout_minutes || 60,
      gates: length(stage.gates || []),
      rules: Enum.map(stage.rules || [], &rule_label/1),
      agent: stage.agent,
      delivers?: delivery != :none and not parallel?,
      chips: node_chips(stage),
      state: layers.state.(index),
      metrics: layers.metrics.(index),
      diff: layers.diff.(stage)
    }
  end

  @compared ~w(name prompt max_attempts model max_budget_usd timeout_minutes output_schema gates rules agent group)a

  defp diff(stage, before) do
    case Enum.find(before, &(&1.key == stage.key)) do
      nil -> :added
      old -> if Map.take(old, @compared) == Map.take(stage, @compared), do: nil, else: :changed
    end
  end

  defp removed(nil, _stages), do: []

  defp removed(before, stages) do
    keys = MapSet.new(stages, & &1.key)
    for stage <- before.stages, not MapSet.member?(keys, stage.key), do: stage.name
  end

  # The node shows its attempts apart, and a model only when one is set.
  defp node_chips(stage) do
    Enum.reject(chips(stage), fn {icon, _text} ->
      icon == "hero-arrow-path" or (icon == "hero-sparkles" and not present?(stage.model))
    end)
  end

  defp edges(nodes) do
    for node <- nodes,
        {kind, label} <- [{:failure, @failure} | Enum.map(node.rules, &{:rule, &1})] do
      %{index: node.index, kind: kind, label: label, active?: node.state == :awaiting}
    end
  end

  defp delivery("commit"), do: :commit
  defp delivery("pr"), do: :pr
  defp delivery(_none), do: :none

  defp cost_cap(nil), do: nil
  defp cost_cap(cost), do: "US$ #{cost}"

  defp names(map) when is_map(map), do: map |> Map.keys() |> Enum.sort()
  defp names(_none), do: []

  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(count, _one, many), do: "#{count} #{many}"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
