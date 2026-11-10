defmodule PipeMaestro.Jobs.EventTest do
  use ExUnit.Case, async: true

  alias PipeMaestro.Jobs.Event

  @metadata_keys ~w(
    name tool_name id tool_use_id parent_tool_use_id
    duration_ms duration_api_ms ttft_ms delay_ms
    usage model_usage cost_usd
    is_error error status subtype stop_reason terminal_reason
    model num_turns pre_tokens attempt max_retries
  )

  test "metadata_keys/0: what an event keeps once its content goes" do
    assert Enum.sort(Event.metadata_keys()) == Enum.sort(@metadata_keys)
  end

  describe "metadata_only/1" do
    test "a tool call keeps its name, id and parent; its arguments go" do
      data = %{
        "id" => "t1",
        "name" => "Bash",
        "text" => "cat segredo.ex",
        "input" => %{"command" => "cat segredo.ex"},
        "parent_tool_use_id" => "task1"
      }

      assert Event.metadata_only(data) == %{
               "id" => "t1",
               "name" => "Bash",
               "parent_tool_use_id" => "task1"
             }
    end

    test "a tool result keeps the call it answers and whether it failed" do
      data = %{
        "tool_use_id" => "t1",
        "text" => "defmodule Segredo do",
        "is_error" => true,
        "decision" => %{"decision" => "reject", "source" => "user"}
      }

      assert Event.metadata_only(data) == %{"tool_use_id" => "t1", "is_error" => true}
    end

    test "the result keeps cost, durations, tokens and why it ended; the text goes" do
      data = %{
        "text" => "Pronto: alterei lib/segredo.ex",
        "is_error" => false,
        "subtype" => "success",
        "stop_reason" => "end_turn",
        "terminal_reason" => "completed",
        "session_id" => "s1",
        "cost_usd" => 0.42,
        "duration_ms" => 1200,
        "duration_api_ms" => 900,
        "ttft_ms" => 300,
        "num_turns" => 4,
        "usage" => %{"input" => 10, "output" => 5},
        "model_usage" => %{"claude-sonnet-5-5" => %{"cost_usd" => 0.42}},
        "structured_output" => %{"resumo" => "segredo"},
        "todos" => [%{"content" => "ler segredo"}]
      }

      assert Event.metadata_only(data) == %{
               "is_error" => false,
               "subtype" => "success",
               "stop_reason" => "end_turn",
               "terminal_reason" => "completed",
               "cost_usd" => 0.42,
               "duration_ms" => 1200,
               "duration_api_ms" => 900,
               "ttft_ms" => 300,
               "num_turns" => 4,
               "usage" => %{"input" => 10, "output" => 5},
               "model_usage" => %{"claude-sonnet-5-5" => %{"cost_usd" => 0.42}}
             }
    end

    test "what the agent said or thought keeps only its tokens and duration" do
      assert Event.metadata_only(%{"text" => "Vou ler o código", "usage" => %{"output" => 3}}) ==
               %{"usage" => %{"output" => 3}}

      assert Event.metadata_only(%{"text" => "pensando…", "duration_ms" => 400}) ==
               %{"duration_ms" => 400}

      assert Event.metadata_only(%{"arguments" => %{"a" => 1}}) == %{}
    end
  end
end
