defmodule PipeMaestroWeb.PipelineLive.StageParamsTest do
  use ExUnit.Case, async: true

  alias PipeMaestroWeb.PipelineLive.StageParams

  defp stages(names), do: Enum.map(names, &%{"name" => &1})
  defp names(stages), do: Enum.map(stages, & &1["name"])

  describe "list/1 and indexed/1" do
    test "a form's stages, by position, and back" do
      params = %{
        "stages" => %{"10" => %{"name" => "k"}, "2" => %{"name" => "c"}, "0" => %{"name" => "a"}}
      }

      assert params |> StageParams.list() |> names() == ["a", "c", "k"]

      assert StageParams.indexed(stages(["a", "b"])) == %{
               "0" => %{"name" => "a"},
               "1" => %{"name" => "b"}
             }
    end

    test "no stages is an empty list" do
      assert StageParams.list(%{}) == []
    end
  end

  test "new/0 is a blank stage with two attempts" do
    assert StageParams.new() == %{"name" => "", "prompt" => "", "max_attempts" => "2"}
  end

  describe "move/3" do
    test "moves a stage to another position" do
      assert stages(~w(a b c)) |> StageParams.move(0, 2) |> names() == ~w(b c a)
      assert stages(~w(a b c)) |> StageParams.move(2, 1) |> names() == ~w(a c b)
    end

    test "a position out of the list changes nothing" do
      assert stages(~w(a b)) |> StageParams.move(0, -1) |> names() == ~w(a b)
      assert stages(~w(a b)) |> StageParams.move(1, 2) |> names() == ~w(a b)
    end
  end

  defp grouped(pairs),
    do: Enum.map(pairs, fn {name, group} -> %{"name" => name, "group" => group} end)

  defp groups(stages), do: Enum.map(stages, &(&1["group"] || ""))

  describe "insert_at/3" do
    test "puts a blank stage at a position" do
      assert stages(~w(a b)) |> StageParams.insert_at(1) |> names() == ["a", "", "b"]
      assert stages(~w(a b)) |> StageParams.insert_at(2) |> names() == ["a", "b", ""]
    end
  end

  describe "join_group/2" do
    test "joins the stage to the one before, in a new group" do
      stages = StageParams.join_group(grouped([{"a", ""}, {"b", ""}, {"c", ""}]), 2)
      assert groups(stages) == ["", "paralelo-1", "paralelo-1"]
    end

    test "joins the group of the one before" do
      stages = StageParams.join_group(grouped([{"a", ""}, {"b", "r"}, {"c", "r"}, {"d", ""}]), 3)
      assert groups(stages) == ["", "r", "r", "r"]
    end

    test "a new group's name is not taken" do
      stages =
        grouped([{"a", ""}, {"b", "paralelo-1"}, {"c", "paralelo-1"}, {"d", ""}, {"e", ""}])

      assert stages |> StageParams.join_group(4) |> groups() ==
               ["", "paralelo-1", "paralelo-1", "paralelo-2", "paralelo-2"]
    end

    test "the first two stages never join: the first prepares the worktree" do
      stages = grouped([{"a", ""}, {"b", ""}])
      assert StageParams.join_group(stages, 1) == stages
      assert StageParams.join_group(stages, 0) == stages
    end
  end

  describe "leave_group/2" do
    test "takes a stage out of its group" do
      stages = grouped([{"a", ""}, {"b", "r"}, {"c", "r"}, {"d", "r"}])
      assert stages |> StageParams.leave_group(3) |> groups() == ["", "r", "r", ""]
    end

    test "a group left with one stage is no group" do
      stages = grouped([{"a", ""}, {"b", "r"}, {"c", "r"}])
      assert stages |> StageParams.leave_group(2) |> groups() == ["", "", ""]
    end

    test "leaving from the middle splits the group in two runs" do
      stages = grouped([{"a", ""}, {"b", "r"}, {"c", "r"}, {"d", "r"}, {"e", "r"}, {"f", "r"}])

      assert stages |> StageParams.leave_group(3) |> groups() ==
               ["", "r", "r", "", "r", "r"]
    end
  end

  describe "a structure that stays valid" do
    test "moving a stage out of its group leaves no group of one" do
      stages = grouped([{"a", ""}, {"b", "r"}, {"c", "r"}, {"d", ""}])
      moved = StageParams.move(stages, 2, 3)

      assert names(moved) == ~w(a b d c)
      assert groups(moved) == ["", "", "", ""]
    end

    test "a stage moved first leaves its group" do
      stages = grouped([{"a", ""}, {"b", "r"}, {"c", "r"}, {"d", "r"}])
      moved = StageParams.move(stages, 2, 0)

      assert names(moved) == ~w(c a b d)
      assert groups(moved) == ["", "", "r", "r"]
    end
  end
end
