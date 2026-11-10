defmodule PipeMaestroProtocol.RunnerLogTest do
  use ExUnit.Case, async: true

  alias PipeMaestroProtocol.RunnerLog

  @at ~U[2026-11-06 10:00:00Z]

  test "a line round-trips; an event keeps its plain attributes" do
    plain = RunnerLog.line(@at, "info", "Online como build-01")

    event =
      RunnerLog.line(@at, "error", "Atualização falhou", "update_failed", %{
        version: "2026-11-06.01",
        attempt: 2,
        nested: %{"no" => true},
        kind: :network
      })

    assert {:ok, [first, second]} = RunnerLog.parse(%{"lines" => [plain, event]})

    assert first == %{
             "at" => @at,
             "level" => "info",
             "message" => "Online como build-01",
             "event" => nil,
             "attrs" => %{}
           }

    assert second["event"] == "update_failed"
    assert second["attrs"] == %{"version" => "2026-11-06.01", "attempt" => 2, "kind" => "network"}
  end

  test "an unknown event is a plain line; a long message is cut" do
    line = RunnerLog.line(@at, "info", String.duplicate("a", 10_000), "made_up", %{"x" => 1})
    refute Map.has_key?(line, "event")
    assert byte_size(line["message"]) <= RunnerLog.max_message_bytes()

    forged = Map.merge(line, %{"event" => "made_up", "attrs" => %{"x" => 1}})
    assert {:ok, [%{"event" => nil, "attrs" => %{}}]} = RunnerLog.parse(%{"lines" => [forged]})
  end

  test "refuses a bad line or too many" do
    assert {:error, _} =
             RunnerLog.parse(%{
               "lines" => [%{"at" => "ontem", "level" => "info", "message" => "x"}]
             })

    assert {:error, _} =
             RunnerLog.parse(%{
               "lines" => [%{"at" => "2026-11-06T10:00:00Z", "level" => "loud", "message" => "x"}]
             })

    assert {:error, _} =
             RunnerLog.parse(%{"lines" => List.duplicate(RunnerLog.line(@at, "info", "x"), 201)})

    assert {:error, _} = RunnerLog.parse(%{})
  end

  test "the join's reply says whether the log lines are kept" do
    assert RunnerLog.logs?(%{"telemetry" => RunnerLog.telemetry_reply(false)}) == false
    assert RunnerLog.logs?(%{"telemetry" => RunnerLog.telemetry_reply(true)})
    assert RunnerLog.logs?(%{"runner_id" => "r1"})
  end

  test "the CLI's sessions not found where expected are an event" do
    assert "claude_sessions_not_found" in RunnerLog.events()

    line =
      RunnerLog.line(
        @at,
        "warning",
        "As sessões do claude não estavam lá",
        "claude_sessions_not_found",
        %{
          "task_id" => "t1",
          "dir" => "/home/r/.claude/projects/-w-worktrees-t1",
          "reason" => "not_found",
          "cli_version" => "2.1.319"
        }
      )

    assert {:ok, [%{"event" => "claude_sessions_not_found", "attrs" => %{"task_id" => "t1"}}]} =
             RunnerLog.parse(%{"lines" => [line]})
  end

  test "a runner draining its jobs before updating is an event" do
    assert "update_draining" in RunnerLog.events()

    line =
      RunnerLog.line(@at, "info", "Terminando 1 job antes de atualizar", "update_draining", %{
        jobs: 1,
        timeout_ms: 1_800_000
      })

    assert {:ok, [%{"event" => "update_draining", "attrs" => %{"jobs" => 1}}]} =
             RunnerLog.parse(%{"lines" => [line]})
  end
end
