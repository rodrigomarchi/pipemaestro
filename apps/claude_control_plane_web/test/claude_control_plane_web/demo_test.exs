defmodule ClaudeControlPlaneWeb.DemoTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneWeb.Demo

  test "every task sits in a known stage" do
    stage_ids = MapSet.new(Demo.stages(), & &1.id)

    for task <- Demo.tasks(), do: assert(task.stage in stage_ids)
  end

  test "tasks_by_stage keeps every stage, even empty ones" do
    grouped = Demo.tasks_by_stage()

    assert Map.keys(grouped) |> Enum.sort() == Demo.stages() |> Enum.map(& &1.id) |> Enum.sort()
    assert grouped |> Map.values() |> List.flatten() |> length() == length(Demo.tasks())
  end

  test "every decision points at an existing task" do
    task_ids = MapSet.new(Demo.tasks(), & &1.id)

    for decision <- Demo.decisions(), do: assert(decision.task_id in task_ids)
  end
end
