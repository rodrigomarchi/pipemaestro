defmodule PipeMaestroWeb.PipelineLive.StageParams do
  @moduledoc """
  The stages of a pipeline's form params (`%{"stages" => %{"0" => ...}}`) as
  a list, and the changes the editor makes to it: a stage moved, inserted,
  put in a parallel group or taken out of one. Params stay as typed, so a
  change to the structure keeps whatever was written in each stage.
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
      List.insert_at(rest, to, stage)
    else
      stages
    end
  end
end
