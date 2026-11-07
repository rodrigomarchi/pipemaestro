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
end
