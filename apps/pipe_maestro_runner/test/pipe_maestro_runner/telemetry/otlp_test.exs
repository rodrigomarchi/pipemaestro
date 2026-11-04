defmodule PipeMaestroRunner.Telemetry.OtlpTest do
  use ExUnit.Case, async: true

  alias PipeMaestroRunner.Telemetry.Otlp

  # A real run's OTLP export (http/json), with the account data removed.
  @fixtures Path.expand("../../fixtures/claude_run", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> JSON.decode!()

  test "the logs become records of the job named in the resource" do
    records = Otlp.records(fixture("otlp_logs.json"))

    assert Enum.all?(records, &match?({"captura-1", _record}, &1))
    names = records |> Enum.map(fn {_job, record} -> record["name"] end) |> Enum.frequencies()

    assert names["api_request"] == 3
    assert names["tool_result"] == 3
    assert names["tool_decision"] == 3
    assert names["mcp_server_connection"] == 6
    refute Map.has_key?(names, "plugin_loaded")

    {_job, request} = Enum.find(records, fn {_job, r} -> r["name"] == "api_request" end)
    assert request["at"] == "2026-11-03T21:28:13.171Z"

    assert %{
             "model" => "claude-haiku-5-5",
             "duration_ms" => 1913,
             "ttft_ms" => 648,
             "input_tokens" => 2,
             "cache_read_tokens" => 11_382,
             "cache_creation_tokens" => 12_282
           } = request["attrs"]

    {_job, tool} = Enum.find(records, fn {_job, r} -> r["name"] == "tool_result" end)
    assert %{"tool_name" => "Read", "success" => true, "duration_ms" => 2} = tool["attrs"]

    refute Enum.any?(records, fn {_job, r} -> Map.has_key?(r["attrs"], "session.id") end)
  end

  test "the metrics become records of their increment" do
    records = Otlp.records(fixture("otlp_metrics.json"))

    lines =
      for {"captura-1", %{"name" => "metric:lines_of_code", "attrs" => attrs}} <- records,
          do: {attrs["type"], attrs["value"]}

    assert {"added", 2} in lines
    assert {"removed", 0} in lines

    assert Enum.any?(records, fn {_job, r} ->
             r["name"] == "metric:active_time" and r["attrs"]["value"] == 4.784
           end)

    refute Enum.any?(records, fn {_job, r} -> r["name"] == "metric:token.usage" end)
  end

  test "an export without the job's attribute or out of shape gives nothing" do
    assert Otlp.records(%{"resourceLogs" => [%{"resource" => %{"attributes" => []}}]}) == []
    assert Otlp.records(%{"anything" => 1}) == []
  end
end
