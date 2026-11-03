defmodule ClaudeControlPlane.Pipelines.JsonTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlane.Pipelines.Json

  test "indents, keeps nulls, numbers and accents, and reads back as it was" do
    value = %{"mcpServers" => %{"g" => %{"args" => ["a", 1, 2.5], "env" => nil, "t" => "ção"}}}
    pretty = Json.pretty(value)

    assert pretty =~ ~s(\n  "mcpServers": {)
    assert pretty =~ ~s("env": null)
    refute String.ends_with?(pretty, "\n")
    assert JSON.decode!(pretty) == value
  end
end
