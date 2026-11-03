defmodule ClaudeControlPlaneProtocol.JobTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneProtocol.{Job, JobEvent}

  describe "Job" do
    test "validates and round-trips through the wire form" do
      assert {:ok, job} = Job.new(%{id: "job-1", prompt: "diga oi"})
      assert Job.to_map(job) == %{"id" => "job-1", "prompt" => "diga oi"}
      assert Job.from_map(Job.to_map(job)) == {:ok, job}
    end

    test "carries a task's context, omitting what is not set" do
      assert {:ok, job} =
               Job.new(%{
                 "id" => "j",
                 "prompt" => "p",
                 "directory" => "retro_hex_chat",
                 "worktree" => %{"task_id" => "t1", "branch" => "cp/t1"},
                 "output_schema" => %{"type" => "object"},
                 "model" => "haiku",
                 "max_budget_usd" => 0.5,
                 "artifact_path" => ".control-plane/t1/01-triagem.md",
                 "setup" => %{"command" => "mix deps.get", "copy" => ["deps", "_build"]},
                 "timeout_ms" => 600_000,
                 "system_prompt" => "Responda em português.",
                 "mcp_config" => %{"mcpServers" => %{"grafana" => %{"command" => "mcp-grafana"}}},
                 "agents" => %{"revisor" => %{"description" => "Revisa", "prompt" => "Revise."}},
                 "agent" => "revisor",
                 "parallel" => true,
                 "env" => %{"GRAFANA_TOKEN" => "segredo"},
                 "delivery" => %{
                   "commit_message" => "Triagem: o botão não responde",
                   "push" => true,
                   "pr" => %{"title" => "Corrigir login", "body" => "Closes #1", "ready" => false},
                   "issue_comment" => %{
                     "url" => "https://github.com/a/b/issues/1",
                     "body" => "Decisão: x"
                   }
                 },
                 "permissions" => %{
                   "profile" => "leitura",
                   "allow" => ["Bash(mix test:*)"],
                   "deny" => ["WebFetch"]
                 },
                 "gates" => [
                   %{"command" => "mix test", "expect" => "pass"},
                   %{"command" => "mix test test/repro_test.exs", "expect" => "fail"}
                 ]
               })

      wire = Job.to_map(job)
      assert wire["directory"] == "retro_hex_chat"
      assert wire["worktree"] == %{"task_id" => "t1", "branch" => "cp/t1"}
      assert Job.from_map(wire) == {:ok, job}
      refute Map.has_key?(Job.to_map(%Job{id: "j", prompt: "p"}), "directory")

      # Setup may name only a command, or only what to copy (paths inside the
      # directory, possibly nested).
      assert {:ok, %Job{setup: %{"copy" => ["vendor/bundle"]}}} =
               Job.new(%{id: "j", prompt: "p", setup: %{"copy" => ["vendor/bundle"]}})

      assert {:ok, %Job{setup: %{"command" => "make"}}} =
               Job.new(%{id: "j", prompt: "p", setup: %{"command" => "make"}})
    end

    test "rejects a bad context" do
      base = %{id: "j", prompt: "p"}
      assert {:error, "directory" <> _} = Job.new(Map.put(base, :directory, "../etc"))
      assert {:error, "directory" <> _} = Job.new(Map.put(base, :directory, "a/b"))
      assert {:error, "worktree" <> _} = Job.new(Map.put(base, :worktree, %{"task_id" => "t"}))
      assert {:error, "output_schema" <> _} = Job.new(Map.put(base, :output_schema, "x"))
      assert {:error, "model" <> _} = Job.new(Map.put(base, :model, ""))
      assert {:error, "max_budget_usd" <> _} = Job.new(Map.put(base, :max_budget_usd, 0))
      assert {:error, "artifact_path" <> _} = Job.new(Map.put(base, :artifact_path, "/etc/x"))
      assert {:error, "artifact_path" <> _} = Job.new(Map.put(base, :artifact_path, "a/../../x"))
      assert {:error, "artifact_path" <> _} = Job.new(Map.put(base, :artifact_path, 1))
      assert {:error, "setup" <> _} = Job.new(Map.put(base, :setup, "mix deps.get"))
      assert {:error, "setup" <> _} = Job.new(Map.put(base, :setup, %{"command" => ""}))
      assert {:error, "setup" <> _} = Job.new(Map.put(base, :setup, %{"copy" => ["../x"]}))
      assert {:error, "setup" <> _} = Job.new(Map.put(base, :setup, %{"copy" => ["/abs"]}))
      assert {:error, "timeout_ms" <> _} = Job.new(Map.put(base, :timeout_ms, 0))
      assert {:error, "timeout_ms" <> _} = Job.new(Map.put(base, :timeout_ms, 1.5))
      assert {:error, "system_prompt" <> _} = Job.new(Map.put(base, :system_prompt, ""))
      assert {:error, "mcp_config" <> _} = Job.new(Map.put(base, :mcp_config, %{"x" => 1}))
      assert {:error, "agents" <> _} = Job.new(Map.put(base, :agents, ["revisor"]))
      assert {:error, "agent" <> _} = Job.new(Map.put(base, :agent, ""))
      assert {:error, "parallel" <> _} = Job.new(Map.put(base, :parallel, "sim"))
      assert {:error, "delivery" <> _} = Job.new(Map.put(base, :delivery, %{}))

      assert {:error, "delivery" <> _} =
               Job.new(Map.put(base, :delivery, %{"commit_message" => ""}))

      assert {:error, "delivery" <> _} =
               Job.new(
                 Map.put(base, :delivery, %{"commit_message" => "x", "pr" => %{"title" => ""}})
               )

      assert {:error, "env" <> _} = Job.new(Map.put(base, :env, %{"lower" => "x"}))
      assert {:error, "env" <> _} = Job.new(Map.put(base, :env, %{"PATH" => "x"}))
      assert {:error, "env" <> _} = Job.new(Map.put(base, :env, %{"OK" => 1}))
      assert {:error, "permissions" <> _} = Job.new(Map.put(base, :permissions, %{}))

      assert {:error, "permissions" <> _} =
               Job.new(Map.put(base, :permissions, %{"profile" => "root"}))

      assert {:error, "permissions" <> _} =
               Job.new(Map.put(base, :permissions, %{"profile" => "edicao", "allow" => [""]}))

      assert {:error, "permissions" <> _} =
               Job.new(Map.put(base, :permissions, %{"profile" => "edicao", "deny" => "Bash"}))

      assert {:error, "gates" <> _} = Job.new(Map.put(base, :gates, "mix test"))
      assert {:error, "gates" <> _} = Job.new(Map.put(base, :gates, [%{"command" => "x"}]))

      assert {:error, "gates" <> _} =
               Job.new(Map.put(base, :gates, [%{"command" => "", "expect" => "pass"}]))

      assert {:error, "gates" <> _} =
               Job.new(Map.put(base, :gates, [%{"command" => "x", "expect" => "maybe"}]))
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
        "apiKeySource" => "none",
        "permissionMode" => "dontAsk",
        "tools" => ["Bash"]
      }

      assert [%JobEvent{type: "system", data: data}] = JobEvent.from_stream_json(line)
      assert data["model"] == "claude-haiku-5-5"
      assert data["cwd"] == "/work"
      assert data["auth"] == "none"
      assert data["permission_mode"] == "dontAsk"
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

    test "the first event of a message carries the turn's tokens" do
      line = %{
        "type" => "assistant",
        "message" => %{
          "usage" => %{
            "input_tokens" => 10,
            "cache_read_input_tokens" => 2_000,
            "cache_creation_input_tokens" => 300,
            "output_tokens" => 150
          },
          "content" => [
            %{"type" => "text", "text" => "olhando"},
            %{
              "type" => "tool_use",
              "id" => "t1",
              "name" => "Read",
              "input" => %{"file_path" => "a"}
            }
          ]
        }
      }

      assert [first, second] = JobEvent.from_stream_json(line)
      assert first.data["usage"] == %{"input" => 2_310, "output" => 150}
      refute Map.has_key?(second.data, "usage")
    end

    test "tool calls carry their id and the input worth showing, cut" do
      long = String.duplicate("x", 5_000)

      line = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "Edit",
              "input" => %{
                "file_path" => "/w/lib/a.ex",
                "old_string" => "velho",
                "new_string" => long,
                "replace_all" => false
              }
            },
            %{
              "type" => "tool_use",
              "id" => "toolu_2",
              "name" => "Bash",
              "input" => %{
                "command" => "mix test",
                "description" => "Roda a suíte",
                "timeout" => 1
              }
            },
            %{
              "type" => "tool_use",
              "id" => "toolu_3",
              "name" => "TodoWrite",
              "input" => %{
                "todos" => [
                  %{"content" => "Reproduzir", "status" => "completed", "activeForm" => "x"},
                  %{"content" => "Corrigir", "status" => "in_progress"}
                ]
              }
            },
            %{
              "type" => "tool_use",
              "id" => "toolu_4",
              "name" => "Mystery",
              "input" => %{"a" => 1}
            }
          ]
        }
      }

      assert [edit, bash, todo, mystery] = JobEvent.from_stream_json(line)
      assert edit.data["id"] == "toolu_1"
      assert edit.data["input"]["file_path"] == "/w/lib/a.ex"
      assert edit.data["input"]["old_string"] == "velho"
      assert byte_size(edit.data["input"]["new_string"]) <= 4_000
      refute Map.has_key?(edit.data["input"], "replace_all")

      assert bash.data["input"] == %{"command" => "mix test", "description" => "Roda a suíte"}

      assert todo.data["input"]["todos"] == [
               %{"content" => "Reproduzir", "status" => "completed"},
               %{"content" => "Corrigir", "status" => "in_progress"}
             ]

      refute Map.has_key?(mystery.data, "input")
    end

    test "a tool result names the call it answers" do
      line = %{
        "type" => "user",
        "message" => %{
          "content" => [%{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "ok"}]
        }
      }

      assert [%JobEvent{data: %{"tool_use_id" => "toolu_1"}}] = JobEvent.from_stream_json(line)
    end

    test "tool results, as a string or as content parts" do
      line = %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "content" => "File created", "is_error" => false},
            %{
              "type" => "tool_result",
              "content" => [
                %{"type" => "text", "text" => "boom"},
                %{"type" => "image"},
                %{"type" => "tool_reference"},
                %{"type" => "tool_reference"}
              ],
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
                 data: %{"text" => "boom\n[image]\n[tool_reference ×2]", "is_error" => true}
               }
             ] = JobEvent.from_stream_json(line)
    end

    test "the result line carries the structured output when there is one" do
      line = %{"type" => "result", "result" => "{}", "structured_output" => %{"status" => "ok"}}

      assert [%JobEvent{data: %{"structured_output" => %{"status" => "ok"}}}] =
               JobEvent.from_stream_json(line)
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
               "num_turns" => 3,
               "structured_output" => nil
             }
    end

    test "partial message lines give the text being written, and are no events" do
      delta = %{
        "type" => "stream_event",
        "event" => %{
          "type" => "content_block_delta",
          "delta" => %{"type" => "text_delta", "text" => "El"}
        }
      }

      assert JobEvent.text_delta(delta) == "El"
      assert JobEvent.from_stream_json(delta) == []

      assert JobEvent.text_delta(%{
               "type" => "stream_event",
               "event" => %{"type" => "message_stop"}
             }) == nil

      assert JobEvent.text_delta(%{"type" => "assistant"}) == nil
      assert Job.delta_event() == "job:delta"
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
