defmodule PipeMaestroProtocol.RunnerDoctorTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.RunnerDoctor

  @checks [
    %{key: "git", name: "git", status: :ok, detail: "git version 2.47"},
    %{key: "disk", name: "Disco", status: :warning, detail: "pouco espaço"}
  ]

  test "a diagnosis round-trips, answering its request" do
    wire = RunnerDoctor.to_map(@checks, ~U[2026-11-06 10:00:00Z], "req-1")
    assert {:ok, parsed} = RunnerDoctor.parse(wire)
    assert parsed["request_id"] == "req-1"
    assert parsed["at"] == ~U[2026-11-06 10:00:00Z]

    assert [%{"key" => "git", "status" => "ok"}, %{"key" => "disk", "status" => "warning"}] =
             parsed["checks"]

    assert {:ok, %{"request_id" => nil}} =
             RunnerDoctor.parse(RunnerDoctor.to_map(@checks, ~U[2026-11-06 10:00:00Z]))
  end

  test "refuses a bad check or time" do
    wire = RunnerDoctor.to_map(@checks, ~U[2026-11-06 10:00:00Z])
    bad_status = put_in(wire, ["checks", Access.at(0), "status"], "maybe")
    bad_key = put_in(wire, ["checks", Access.at(0), "key"], "Não")

    assert {:error, _} = RunnerDoctor.parse(bad_status)
    assert {:error, _} = RunnerDoctor.parse(bad_key)
    assert {:error, _} = RunnerDoctor.parse(%{wire | "at" => "ontem"})
    assert {:error, _} = RunnerDoctor.parse(%{})
    assert RunnerDoctor.event() == "runner:doctor"
    assert RunnerDoctor.interval_ms() == 3_600_000
  end
end
