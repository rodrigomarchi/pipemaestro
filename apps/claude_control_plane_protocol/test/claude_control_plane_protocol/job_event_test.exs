defmodule ClaudeControlPlaneProtocol.JobEventTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneProtocol.JobEvent

  # A real run of `claude -p --output-format stream-json --verbose` (haiku,
  # reading a README, running ls and writing a file), with paths and account
  # data replaced.
  @fixture Path.expand("../fixtures/claude_run/stream.jsonl", __DIR__)

  defp run_events do
    @fixture
    |> File.stream!()
    |> Enum.flat_map(&JobEvent.from_stream_json(JSON.decode!(&1)))
  end

  describe "a real run" do
    test "the init keeps the session and what the agent had at hand" do
      [%JobEvent{type: "system", data: data} | _rest] = run_events()

      assert data["session_id"] == "495c515b-822d-4089-b55d-3dcc9b8a0500"
      assert data["version"] == "2.1.317"
      assert data["permission_mode"] == "acceptEdits"
      assert "Bash" in data["tools"]
      assert %{"name" => "grafana", "status" => "pending"} in data["mcp_servers"]
      assert "Explore" in data["agents"]
      assert "dataviz" in data["skills"]
      assert %{"name" => "claude-hud", "version" => "0.3.0"} in data["plugins"]
      assert data["output_style"] == "default"
      assert is_list(data["slash_commands"])
    end

    test "thinking, the turns' tokens with the cache apart, and each tool's permission" do
      events = run_events()

      assert %JobEvent{data: thinking} = Enum.find(events, &(&1.type == "thinking"))
      assert thinking["duration_ms"] == 615
      assert thinking["usage"]["message_id"] == "msg_011CgghoqHZLBcRveLTFjTqb"

      assert thinking["usage"] == %{
               "message_id" => "msg_011CgghoqHZLBcRveLTFjTqb",
               "model" => "claude-haiku-5-5",
               "input" => 2 + 12_282 + 11_382,
               "fresh_input" => 2,
               "cache_read" => 11_382,
               "cache_creation" => 12_282,
               "output" => 3
             }

      [read | _rest] = for %JobEvent{type: "tool_result"} = event <- events, do: event
      assert read.data["decision"] == %{"decision" => "accept", "source" => "config"}

      assert %JobEvent{data: %{"status" => "allowed", "window" => "five_hour"} = limit} =
               Enum.find(events, &(&1.type == "rate_limit"))

      assert limit["utilization"] == %{"five_hour" => 0.02, "seven_day" => 0.12}
    end

    test "the result keeps the run's totals" do
      %JobEvent{data: result} = run_events() |> Enum.find(&(&1.type == "result"))

      assert result["session_id"] == "495c515b-822d-4089-b55d-3dcc9b8a0500"
      assert result["subtype"] == "success"
      assert result["stop_reason"] == "end_turn"
      assert result["terminal_reason"] == "completed"
      assert result["duration_api_ms"] == 4054
      assert result["ttft_ms"] == 1295
      assert result["num_turns"] == 4

      assert result["usage"] == %{
               "fresh_input" => 6,
               "cache_read" => 60_503,
               "cache_creation" => 14_376,
               "output" => 567,
               "thinking" => 118
             }

      assert result["model_usage"] == %{
               "claude-haiku-5-5" => %{
                 "fresh_input" => 6,
                 "output" => 567,
                 "cache_read" => 60_503,
                 "cache_creation" => 14_376,
                 "cost_usd" => 0.00376433
               }
             }

      assert result["permission_denials"] == []
      assert result["subagents"] == %{"spawned" => 0, "completed" => 0, "failed" => 0}
    end
  end

  describe "lines the run above did not have" do
    test "an API retry, a compaction and a denied permission" do
      assert [%JobEvent{type: "api_retry", data: retry}] =
               JobEvent.from_stream_json(%{
                 "type" => "system",
                 "subtype" => "api_retry",
                 "attempt" => 2,
                 "max_retries" => 10,
                 "retry_delay_ms" => 1200,
                 "error_status" => 529,
                 "error" => "overloaded"
               })

      assert retry == %{
               "attempt" => 2,
               "max_retries" => 10,
               "delay_ms" => 1200,
               "status" => 529,
               "error" => "overloaded",
               "text" => "Tentativa 2 de 10 da API: overloaded"
             }

      assert [%JobEvent{type: "compact", data: %{"trigger" => "auto", "pre_tokens" => 150_000}}] =
               JobEvent.from_stream_json(%{
                 "type" => "system",
                 "subtype" => "compact_boundary",
                 "compact_metadata" => %{"trigger" => "auto", "pre_tokens" => 150_000}
               })

      assert [%JobEvent{type: "permission_denied", data: denied}] =
               JobEvent.from_stream_json(%{
                 "type" => "system",
                 "subtype" => "permission_denied",
                 "tool_name" => "Bash",
                 "tool_use_id" => "t9",
                 "message" => "rm -rf não é permitido"
               })

      assert denied["tool_name"] == "Bash"
      assert denied["text"] =~ "rm -rf"
    end

    test "a subagent's calls name the call that started it; MCP tools keep their arguments" do
      line = %{
        "type" => "assistant",
        "parent_tool_use_id" => "toolu_task",
        "message" => %{
          "id" => "msg_1",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_mcp",
              "name" => "mcp__grafana__query_loki_logs",
              "input" => %{"query" => "{app=\"x\"}", "limit" => 10}
            }
          ]
        }
      }

      assert [%JobEvent{type: "tool_use", data: data}] = JobEvent.from_stream_json(line)
      assert data["parent_tool_use_id"] == "toolu_task"
      assert JSON.decode!(data["arguments"]) == %{"query" => "{app=\"x\"}", "limit" => 10}
    end

    test "a result with denials, errors and subagents" do
      line = %{
        "type" => "result",
        "subtype" => "error_max_turns",
        "is_error" => true,
        "permission_denials" => [
          %{
            "tool_name" => "Bash",
            "tool_use_id" => "t1",
            "tool_input" => %{"command" => "rm -rf /"}
          }
        ],
        "errors" => ["atingiu o limite de turnos"],
        "subagent_stats" => %{"spawned" => 2, "completed" => 1, "failed" => 1}
      }

      assert [%JobEvent{data: data}] = JobEvent.from_stream_json(line)

      assert [%{"tool_name" => "Bash", "tool_use_id" => "t1", "input" => input}] =
               data["permission_denials"]

      assert input =~ "rm -rf"
      assert data["errors"] == ["atingiu o limite de turnos"]
      assert data["subagents"] == %{"spawned" => 2, "completed" => 1, "failed" => 1}
      assert data["text"] == "error_max_turns"
    end

    test "thinking with its text, when the run shows it" do
      line = %{
        "type" => "assistant",
        "thinking_duration_ms" => 900,
        "message" => %{
          "id" => "m",
          "content" => [%{"type" => "thinking", "thinking" => "Preciso ler o arquivo antes."}]
        }
      }

      assert [
               %JobEvent{
                 type: "thinking",
                 data: %{"text" => "Preciso ler o arquivo antes.", "duration_ms" => 900}
               }
             ] =
               JobEvent.from_stream_json(line)
    end
  end
end
