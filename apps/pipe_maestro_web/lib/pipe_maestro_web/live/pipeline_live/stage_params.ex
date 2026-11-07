defmodule PipeMaestroWeb.PipelineLive.StageParams do
  @moduledoc """
  The stages of a pipeline's form params (`%{"stages" => %{"0" => ...}}`) as
  a list, and the changes the editor makes to it: a stage moved, inserted,
  put in a parallel group or taken out of one. Params stay as typed, so a
  change to the structure keeps whatever was written in each stage.

  A change to the structure leaves it valid: the first stage, which prepares
  the worktree, is in no group, and a group left with one stage in a row is
  no group.
  """

  @type stage :: %{optional(String.t()) => term()}

  @doc "The stages of a form's params, in order."
  @spec list(map()) :: [stage()]
  def list(params) do
    (params["stages"] || %{})
    |> Enum.sort_by(fn {index, _stage} -> String.to_integer(index) end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc "A list of stages as the form's params, keyed by position."
  @spec indexed([stage()]) :: %{String.t() => stage()}
  def indexed(stages),
    do: stages |> Enum.with_index() |> Map.new(fn {stage, i} -> {Integer.to_string(i), stage} end)

  @doc "A blank stage."
  @spec new() :: stage()
  def new, do: %{"name" => "", "prompt" => "", "max_attempts" => "2"}

  @doc "Moves the stage at `from` to `to`; a `to` out of the list changes nothing."
  @spec move([stage()], non_neg_integer(), integer()) :: [stage()]
  def move(stages, from, to) do
    if to in 0..(length(stages) - 1)//1 do
      {stage, rest} = List.pop_at(stages, from)
      rest |> List.insert_at(to, stage) |> normalize()
    else
      stages
    end
  end

  @doc "Inserts a blank stage at `at`."
  @spec insert_at([stage()], non_neg_integer()) :: [stage()]
  def insert_at(stages, at), do: List.insert_at(stages, at, new())

  @doc "Removes the stage at `index`."
  @spec remove([stage()], non_neg_integer()) :: [stage()]
  def remove(stages, index), do: stages |> List.delete_at(index) |> normalize()

  @doc """
  Runs the stage at `index` at once with the one before: in its group, or in
  a new one with both. Neither the first stage nor the second joins: the
  first is in no group.
  """
  @spec join_group([stage()], non_neg_integer()) :: [stage()]
  def join_group(stages, index) when index >= 2 do
    group =
      case group(Enum.at(stages, index - 1)) do
        nil -> new_group(stages)
        group -> group
      end

    stages
    |> List.update_at(index - 1, &Map.put(&1, "group", group))
    |> List.update_at(index, &Map.put(&1, "group", group))
  end

  def join_group(stages, _index), do: stages

  @doc "Takes the stage at `index` out of its group."
  @spec leave_group([stage()], non_neg_integer()) :: [stage()]
  def leave_group(stages, index),
    do: stages |> List.update_at(index, &Map.put(&1, "group", "")) |> normalize()

  defp new_group(stages) do
    taken = stages |> Enum.map(&group/1) |> MapSet.new()
    n = Enum.find(Stream.iterate(1, &(&1 + 1)), &(not MapSet.member?(taken, "paralelo-#{&1}")))
    "paralelo-#{n}"
  end

  # The first stage in no group, and no group of one stage in a row.
  defp normalize([]), do: []

  defp normalize([first | rest]) do
    stages = [ungroup(first) | rest]
    groups = Enum.map(stages, &group/1)
    previous = [nil | groups]
    next = tl(groups) ++ [nil]

    [stages, groups, previous, next]
    |> Enum.zip()
    |> Enum.map(fn {stage, group, previous, next} ->
      if group != nil and group != previous and group != next, do: ungroup(stage), else: stage
    end)
  end

  defp ungroup(stage), do: if(group(stage), do: Map.put(stage, "group", ""), else: stage)

  defp group(stage) do
    case String.trim(to_string(stage["group"] || "")) do
      "" -> nil
      group -> group
    end
  end
end
