defmodule ClaudeControlPlaneProtocol.TelemetryTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneProtocol.Telemetry

  test "a record keeps known names and attributes, with numbers and booleans as such" do
    assert Telemetry.record("tool_result", "2026-11-03T21:28:12.924Z", %{
             "tool_name" => "Bash",
             "success" => "true",
             "duration_ms" => "664",
             "tool_result_size_bytes" => "163",
             "user.email" => "alguem@exemplo.com",
             "session.id" => "s1"
           }) ==
             %{
               "name" => "tool_result",
               "at" => "2026-11-03T21:28:12.924Z",
               "attrs" => %{
                 "tool_name" => "Bash",
                 "success" => true,
                 "duration_ms" => 664,
                 "tool_result_size_bytes" => 163
               }
             }

    assert %{"attrs" => %{"cost_usd" => 0.0027, "input_tokens" => 2}} =
             Telemetry.record("api_request", "t", %{"cost_usd" => 0.0027, "input_tokens" => "2"})

    assert %{"attrs" => %{"success" => false}} =
             Telemetry.record("tool_result", "t", %{"success" => "false"})

    assert Telemetry.record("plugin_loaded", "t", %{}) == nil
    assert Telemetry.record("metric:lines_of_code", "t", %{"type" => "added", "value" => 2})
  end

  test "long texts are cut and only plain values pass" do
    %{"attrs" => attrs} =
      Telemetry.record("api_error", "t", %{
        "error" => String.duplicate("x", 5_000),
        "model" => %{"nested" => true}
      })

    assert byte_size(attrs["error"]) <= 1_000
    refute Map.has_key?(attrs, "model")
  end

  test "message name and batch size" do
    assert Telemetry.event() == "job:telemetry"
    assert Telemetry.max_records() == 200
    assert "api_request" in Telemetry.names()
  end
end
