defmodule ClaudeControlPlaneProtocol.JobTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneProtocol.{Job, JobEvent}

  describe "Job" do
    test "validates and round-trips through the wire form" do
      assert {:ok, job} = Job.new(%{id: "job-1", prompt: "diga oi"})
      assert Job.to_map(job) == %{"id" => "job-1", "prompt" => "diga oi"}
      assert Job.from_map(Job.to_map(job)) == {:ok, job}
    end

    test "rejects a missing id, an empty or oversized prompt and non-maps" do
      assert {:error, "id" <> _} = Job.new(%{prompt: "x"})
      assert {:error, "prompt" <> _} = Job.new(%{id: "j", prompt: ""})

      assert {:error, "prompt" <> _} =
               Job.new(%{id: "j", prompt: String.duplicate("a", Job.max_prompt_bytes() + 1)})

      assert {:error, _} = Job.new(:nope)
    end

    test "message names and finished statuses" do
      events = [
        Job.assign_event(),
        Job.cancel_event(),
        Job.started_event(),
        Job.event_event(),
        Job.finished_event()
      ]

      assert Enum.all?(events, &String.starts_with?(&1, "job:"))
      assert Enum.uniq(events) == events
      assert Job.finished_statuses() == ~w(succeeded failed canceled)
    end
  end

  # Lines trimmed from a real `claude -p --output-format stream-json --verbose` run.
  describe "JobEvent.from_stream_json/1" do
    test "the init line becomes a system event" do
      line = %{
        "type" => "system",
        "subtype" => "init",
        "cwd" => "/work",
        "model" => "claude-haiku-5-5",
        "claude_code_version" => "2.1.317",
        "tools" => ["Bash"]
      }

      assert [%JobEvent{type: "system", data: data}] = JobEvent.from_stream_json(line)
      assert data["model"] == "claude-haiku-5-5"
      assert data["cwd"] == "/work"
      assert data["text"] =~ "claude-haiku-5-5"
    end

    test "assistant text and tool calls, skipping thinking blocks" do
      line = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "thinking", "thinking" => "", "signature" => "abc"},
            %{"type" => "text", "text" => "feito"},
            %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "ls -la"}},
            %{"type" => "tool_use", "name" => "Write", "input" => %{"file_path" => "/w/a.txt"}},
            %{"type" => "tool_use", "name" => "Odd", "input" => %{"n" => 1}}
          ]
        }
      }

      assert [
               %JobEvent{type: "assistant_text", data: %{"text" => "feito"}},
               %JobEvent{type: "tool_use", data: %{"name" => "Bash", "text" => "ls -la"}},
               %JobEvent{type: "tool_use", data: %{"text" => "/w/a.txt"}},
               %JobEvent{type: "tool_use", data: %{"text" => odd}}
             ] = JobEvent.from_stream_json(line)

      assert odd =~ "n"
    end

    test "tool results, as a string or as content parts" do
      line = %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "content" => "File created", "is_error" => false},
            %{
              "type" => "tool_result",
              "content" => [%{"type" => "text", "text" => "boom"}, %{"type" => "image"}],
              "is_error" => true
            }
          ]
        }
      }

      assert [
               %JobEvent{
                 type: "tool_result",
                 data: %{"text" => "File created", "is_error" => false}
               },
               %JobEvent{
                 type: "tool_result",
                 data: %{"text" => "boom\n[image]", "is_error" => true}
               }
             ] = JobEvent.from_stream_json(line)
    end

    test "the result line carries cost, duration and turns" do
      line = %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "feito",
        "total_cost_usd" => 0.0037,
        "duration_ms" => 5591,
        "num_turns" => 3
      }

      assert [%JobEvent{type: "result", data: data}] = JobEvent.from_stream_json(line)

      assert data == %{
               "text" => "feito",
               "is_error" => false,
               "cost_usd" => 0.0037,
               "duration_ms" => 5591,
               "num_turns" => 3
             }
    end

    test "internal lines are dropped" do
      assert JobEvent.from_stream_json(%{"type" => "system", "subtype" => "thinking_tokens"}) ==
               []

      assert JobEvent.from_stream_json(%{"type" => "rate_limit_event"}) == []
      assert JobEvent.from_stream_json(%{"anything" => true}) == []
    end

    test "long texts are cut at a character boundary" do
      text = String.duplicate("ç", JobEvent.max_text_bytes())

      line = %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => text}]}
      }

      assert [%JobEvent{data: %{"text" => cut}}] = JobEvent.from_stream_json(line)
      assert byte_size(cut) <= JobEvent.max_text_bytes()
      assert String.valid?(cut)
      assert String.ends_with?(cut, "…")
    end

    test "wire form" do
      event = %JobEvent{type: "assistant_text", data: %{"text" => "oi"}}
      assert JobEvent.to_map(event) == %{"type" => "assistant_text", "data" => %{"text" => "oi"}}
      assert "result" in JobEvent.types()
    end
  end
end
