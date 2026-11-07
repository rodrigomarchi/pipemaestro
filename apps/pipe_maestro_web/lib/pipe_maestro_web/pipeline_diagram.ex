defmodule PipeMaestroWeb.PipelineDiagram do
  @moduledoc """
  A pipeline as a diagram, before it is drawn: the entry with the pipeline's
  context, the steps (`PipeMaestro.Pipelines.steps/1`: a stage alone, or a
  group that runs at once), what is delivered, and the rail of the places a
  task stops for a person: a stage that fails or blocks, a rule that matches,
  the cost cap.

  It reads a `PipeMaestro.Pipelines.Pipeline`, saved or a form's draft
  (`Ecto.Changeset.apply_changes/1`), and knows nothing of how it is drawn
  (`PipeMaestroWeb.PipelineComponents.pipeline_diagram/1`).
  """

  alias PipeMaestro.Pipelines
  alias PipeMaestro.Pipelines.{Pipeline, Stage}

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
          chips: [chip()]
        }

  @typedoc "A short fact about a stage: an icon and a text."
  @type chip :: {String.t(), String.t()}

  @typedoc "A stage alone, or the stages of a group, which run at once."
  @type step :: %{parallel?: boolean(), group: String.t() | nil, nodes: [stage_node()]}

  @typedoc "Where a stage stops the task for a person."
  @type edge :: %{index: non_neg_integer(), kind: :failure | :rule, label: String.t()}

  @type t :: %{
          entry: %{
            name: String.t() | nil,
            system_prompt?: boolean(),
            mcp_servers: [String.t()],
            agents: [String.t()]
          },
          steps: [step()],
          delivery: :none | :commit | :pr,
          rail: %{edges: [edge()], cost_cap: String.t() | nil}
        }

  @failure "esgotou ou bloqueou"

  @doc "The diagram of a pipeline."
  @spec build(Pipeline.t()) :: t()
  def build(%Pipeline{stages: stages} = pipeline) do
    delivery = delivery(pipeline.delivery)

    steps =
      for indexes <- Pipelines.steps(stages) do
        first = Enum.at(stages, hd(indexes))
        parallel? = present?(first.group)

        %{
          parallel?: parallel?,
          group: if(parallel?, do: first.group),
          nodes: Enum.map(indexes, &stage_node(Enum.at(stages, &1), &1, delivery, parallel?))
        }
      end

    %{
      entry: %{
        name: pipeline.name,
        system_prompt?: present?(pipeline.system_prompt),
        mcp_servers: names(pipeline.mcp_config && pipeline.mcp_config["mcpServers"]),
        agents: names(pipeline.agents)
      },
      steps: steps,
      delivery: delivery,
      rail: %{edges: edges(steps), cost_cap: cost_cap(pipeline.max_task_cost_usd)}
    }
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

  defp stage_node(%Stage{} = stage, index, delivery, parallel?) do
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
      chips: chips(stage)
    }
  end

  defp edges(steps) do
    for %{nodes: nodes} <- steps,
        node <- nodes,
        edge <- [{:failure, @failure} | Enum.map(node.rules, &{:rule, &1})] do
      {kind, label} = edge
      %{index: node.index, kind: kind, label: label}
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
