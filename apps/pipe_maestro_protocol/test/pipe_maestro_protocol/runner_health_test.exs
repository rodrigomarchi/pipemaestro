defmodule PipeMaestroProtocol.RunnerHealthTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.RunnerHealth

  test "a sample keeps its known fields, the missing ones as nil" do
    assert {:ok, sample} =
             RunnerHealth.parse(%{
               "at" => "2026-11-06T10:00:00Z",
               "cpu_pct" => 12.5,
               "load1" => 1.2,
               "mem_used_bytes" => 8_000,
               "other" => "ignored"
             })

    assert sample["at"] == ~U[2026-11-06 10:00:00Z]
    assert sample["cpu_pct"] == 12.5
    assert sample["disk_free_bytes"] == nil
    refute Map.has_key?(sample, "other")
    assert Enum.sort(Map.keys(sample)) == Enum.sort(["at" | RunnerHealth.fields()])
  end

  test "refuses a sample without a timestamp or with a bad number" do
    assert {:error, _} = RunnerHealth.parse(%{"cpu_pct" => 1})
    assert {:error, _} = RunnerHealth.parse(%{"at" => "ontem"})

    assert {:error, "cpu_pct" <> _} =
             RunnerHealth.parse(%{"at" => "2026-11-06T10:00:00Z", "cpu_pct" => -1})

    assert {:error, _} = RunnerHealth.parse(%{"at" => "2026-11-06T10:00:00Z", "load1" => "1"})
  end

  test "names the message and how often it goes" do
    assert RunnerHealth.event() == "runner:health"
    assert RunnerHealth.interval_ms() == 60_000
  end
end
