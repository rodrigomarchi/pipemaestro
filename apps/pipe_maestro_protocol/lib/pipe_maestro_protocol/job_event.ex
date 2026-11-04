defmodule PipeMaestroProtocol.JobEvent do
  @moduledoc """
  One event of a running job, as the runner reports it.

  The agent CLI (`claude -p --output-format stream-json --verbose`) prints one
  JSON object per line. `from_stream_json/1` turns a line into events with a
  `data` map whose texts are cut at `max_text_bytes/0`, keeping what serves to
  follow the run and to audit it later:

    * `"system"` — the session started: `text`, `session_id`, `model`, `cwd`,
      `version`, `auth` (the CLI's `apiKeySource`: `"none"` for a signed-in
      user's login, else the API key's source), `permission_mode`,
      `output_style` and what the agent had at hand: `tools`, `mcp_servers`
      (`name`, `status`), `agents`, `skills`, `slash_commands` and `plugins`
      (`name`, `version`).
    * `"thinking"` — the model thought before acting: `text` (empty when the
      CLI keeps it hidden) and `duration_ms`.
    * `"assistant_text"` — something the agent said: `text`.
    * `"tool_use"` — a tool call: `id`, `name`, `text` (its main argument),
      for the tools the screens know `input` (the arguments worth showing,
      `tool_inputs/0`, texts cut at `max_input_bytes/0`) and for the others
      `arguments` (their JSON, cut).
    * `"tool_result"` — a tool's answer: `tool_use_id`, `text`, `is_error` and
      the permission `decision` that let it run (`decision`, `source`).
    * `"api_retry"` — a call to the model API failed and is retried:
      `attempt`, `max_retries`, `delay_ms`, `status`, `error`.
    * `"compact"` — the conversation was compacted: `trigger`, `pre_tokens`.
    * `"permission_denied"` — a tool call was refused: `tool_name`,
      `tool_use_id`, `text`.
    * `"rate_limit"` — the account's usage limits: `status`, `window`,
      `utilization` per window (0 to 1), `resets_at`.
    * `"result"` — the run ended: `text`, `is_error`, `subtype`,
      `stop_reason`, `terminal_reason`, `session_id`, `cost_usd`,
      `duration_ms`, `duration_api_ms`, `ttft_ms`, `num_turns`, `usage` (the
      run's tokens), `model_usage` (tokens and cost per model),
      `permission_denials`, `errors`, `subagents` and, when the run was given
      a JSON Schema, `structured_output`.

  Events of a subagent's work carry `parent_tool_use_id`: the call that
  started it. The first event of each of the agent's messages carries the
  message's `usage`: `message_id`, `model`, `fresh_input`, `cache_read`,
  `cache_creation`, `input` (the three summed) and `output`. A message split
  over several lines repeats it: count each `message_id` once.
  """

  alias PipeMaestroProtocol.Text

  @enforce_keys [:type, :data]
  defstruct @enforce_keys

  @type t :: %__MODULE__{type: String.t(), data: %{String.t() => term()}}

  @types ~w(system thinking assistant_text tool_use tool_result api_retry compact
            permission_denied rate_limit result)
  @max_text_bytes 32_000
  @max_input_bytes 16_000
  @max_todos 50
  @max_list 300
  @max_name_bytes 200

  # The arguments of each known tool that a screen shows.
  @tool_inputs %{
    "Bash" => ~w(command description),
    "Edit" => ~w(file_path old_string new_string),
    "MultiEdit" => ~w(file_path),
    "Write" => ~w(file_path content),
    "Read" => ~w(file_path offset limit),
    "Grep" => ~w(pattern path glob),
    "Glob" => ~w(pattern path),
    "WebFetch" => ~w(url),
    "WebSearch" => ~w(query),
    "Task" => ~w(description subagent_type),
    "Agent" => ~w(description subagent_type),
    "TodoWrite" => ~w(todos),
    "NotebookEdit" => ~w(notebook_path)
  }

  # The tool argument worth showing, in order of preference.
  @tool_summary_keys ~w(command file_path pattern url query description prompt)

  @doc "Every event type, as sent on the wire."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The longest text an event carries, in bytes."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc "The longest text in a tool call's `input` or `arguments`, in bytes."
  @spec max_input_bytes() :: pos_integer()
  def max_input_bytes, do: @max_input_bytes

  @doc "The tools whose input events carry, with the arguments kept."
  @spec tool_inputs() :: %{String.t() => [String.t()]}
  def tool_inputs, do: @tool_inputs

  @doc "The events in one decoded `stream-json` line; lines nobody needs give `[]`."
  @spec from_stream_json(map()) :: [t()]
  def from_stream_json(%{"type" => "system", "subtype" => "init"} = line) do
    model = line["model"] || "?"

    [
      event("system", %{
        "text" => "Sessão iniciada (#{model})",
        "session_id" => line["session_id"],
        "model" => model,
        "cwd" => line["cwd"],
        "version" => line["claude_code_version"],
        "auth" => line["apiKeySource"],
        "permission_mode" => line["permissionMode"],
        "output_style" => line["output_style"],
        "tools" => names(line["tools"]),
        "agents" => names(line["agents"]),
        "skills" => names(line["skills"]),
        "slash_commands" => names(line["slash_commands"]),
        "mcp_servers" => entries(line["mcp_servers"], ~w(name status)),
        "plugins" => entries(line["plugins"], ~w(name version))
      })
    ]
  end

  def from_stream_json(%{"type" => "system", "subtype" => "api_retry"} = line) do
    [
      event("api_retry", %{
        "attempt" => line["attempt"],
        "max_retries" => line["max_retries"],
        "delay_ms" => line["retry_delay_ms"],
        "status" => line["error_status"],
        "error" => short(line["error"]),
        "text" =>
          "Tentativa #{line["attempt"]} de #{line["max_retries"]} da API: #{short(line["error"])}"
      })
    ]
  end

  def from_stream_json(%{"type" => "system", "subtype" => "compact_boundary"} = line) do
    metadata = line["compact_metadata"] || %{}

    [
      event("compact", %{
        "trigger" => metadata["trigger"],
        "pre_tokens" => metadata["pre_tokens"],
        "text" => "Conversa compactada (#{metadata["trigger"] || "?"})"
      })
    ]
  end

  def from_stream_json(%{"type" => "system", "subtype" => "permission_denied"} = line) do
    [
      event("permission_denied", %{
        "tool_name" => line["tool_name"],
        "tool_use_id" => line["tool_use_id"],
        "text" => truncate(line["message"] || line["reason"] || "Permissão negada")
      })
    ]
  end

  def from_stream_json(%{"type" => "rate_limit_event", "rate_limit_info" => %{} = info}) do
    utilization =
      for {window, %{"utilization" => value}} <- info["unifiedWindows"] || %{},
          into: %{},
          do: {window, value}

    [
      event("rate_limit", %{
        "status" => info["status"],
        "window" => info["rateLimitType"],
        "utilization" => utilization,
        "resets_at" => info["resetsAt"]
      })
    ]
  end

  def from_stream_json(
        %{"type" => "assistant", "message" => %{"content" => content} = message} = line
      )
      when is_list(content) do
    content
    |> Enum.flat_map(&assistant_block(&1, line))
    |> Enum.map(&put_parent(&1, line["parent_tool_use_id"]))
    |> case do
      [first | rest] -> [put_usage(first, message) | rest]
      [] -> []
    end
  end

  def from_stream_json(%{"type" => "user", "message" => %{"content" => content}} = line)
      when is_list(content) do
    decisions = decisions(line["tool_result_meta"])

    content
    |> Enum.flat_map(&user_block(&1, decisions))
    |> Enum.map(&put_parent(&1, line["parent_tool_use_id"]))
  end

  def from_stream_json(%{"type" => "result"} = line) do
    [
      event("result", %{
        "text" => truncate(line["result"] || line["subtype"] || ""),
        "is_error" => line["is_error"] == true,
        "subtype" => line["subtype"],
        "stop_reason" => line["stop_reason"],
        "terminal_reason" => line["terminal_reason"],
        "session_id" => line["session_id"],
        "cost_usd" => line["total_cost_usd"],
        "duration_ms" => line["duration_ms"],
        "duration_api_ms" => line["duration_api_ms"],
        "ttft_ms" => line["ttft_ms"],
        "num_turns" => line["num_turns"],
        "usage" => run_usage(line["usage"]),
        "model_usage" => model_usage(line["modelUsage"]),
        "permission_denials" => denials(line["permission_denials"]),
        "errors" => line["errors"] |> List.wrap() |> Enum.take(20) |> Enum.map(&short/1),
        "subagents" => subagents(line["subagent_stats"]),
        "structured_output" => line["structured_output"]
      })
    ]
  end

  def from_stream_json(_line), do: []

  @doc """
  The text a partial message line (`--include-partial-messages`) adds to what
  the agent is writing; `nil` for any other line. Partial lines are not
  events: the runner relays them as they come (`job:delta`) and the full
  message arrives later as an `"assistant_text"` event.
  """
  @spec text_delta(map()) :: String.t() | nil
  def text_delta(%{
        "type" => "stream_event",
        "event" => %{
          "type" => "content_block_delta",
          "delta" => %{"type" => "text_delta", "text" => text}
        }
      })
      when is_binary(text),
      do: text

  def text_delta(_line), do: nil

  @doc "The wire form, without the job id and sequence the runner adds."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{type: type, data: data}), do: %{"type" => type, "data" => data}

  # ── Tokens ────────────────────────────────────────────────────────────────

  # The message's tokens: fresh input, read from and written to the cache,
  # and written by the model.
  defp put_usage(event, %{"usage" => %{} = usage} = message) do
    fresh = usage["input_tokens"] || 0
    cache_read = usage["cache_read_input_tokens"] || 0
    cache_creation = usage["cache_creation_input_tokens"] || 0

    %{
      event
      | data:
          Map.put(event.data, "usage", %{
            "message_id" => message["id"],
            "model" => message["model"],
            "input" => fresh + cache_read + cache_creation,
            "fresh_input" => fresh,
            "cache_read" => cache_read,
            "cache_creation" => cache_creation,
            "output" => usage["output_tokens"] || 0
          })
    }
  end

  defp put_usage(event, _message), do: event

  defp run_usage(%{} = usage) do
    %{
      "fresh_input" => usage["input_tokens"] || 0,
      "cache_read" => usage["cache_read_input_tokens"] || 0,
      "cache_creation" => usage["cache_creation_input_tokens"] || 0,
      "output" => usage["output_tokens"] || 0,
      "thinking" => get_in(usage, ["output_tokens_details", "thinking_tokens"]) || 0
    }
  end

  defp run_usage(_usage), do: nil

  defp model_usage(%{} = by_model) do
    for {model, %{} = usage} <- Enum.take(by_model, 20), into: %{} do
      {short(model),
       %{
         "fresh_input" => usage["inputTokens"] || 0,
         "output" => usage["outputTokens"] || 0,
         "cache_read" => usage["cacheReadInputTokens"] || 0,
         "cache_creation" => usage["cacheCreationInputTokens"] || 0,
         "cost_usd" => usage["costUSD"]
       }}
    end
  end

  defp model_usage(_by_model), do: nil

  defp denials(denials) when is_list(denials) do
    for %{} = denial <- Enum.take(denials, 50) do
      %{
        "tool_name" => denial["tool_name"],
        "tool_use_id" => denial["tool_use_id"],
        "input" => json(denial["tool_input"])
      }
    end
  end

  defp denials(_denials), do: []

  defp subagents(%{} = stats),
    do: Map.take(stats, ~w(spawned completed failed)) |> Map.new(fn {k, v} -> {k, v || 0} end)

  defp subagents(_stats), do: nil

  # ── Blocks ────────────────────────────────────────────────────────────────

  defp assistant_block(%{"type" => "thinking"} = block, line),
    do: [
      event("thinking", %{
        "text" => truncate(block["thinking"] || ""),
        "duration_ms" => line["thinking_duration_ms"]
      })
    ]

  defp assistant_block(%{"type" => "text", "text" => text}, _line) when text != "",
    do: [event("assistant_text", %{"text" => truncate(text)})]

  defp assistant_block(%{"type" => "tool_use", "name" => name} = block, _line) do
    data =
      %{"id" => block["id"], "name" => name, "text" => truncate(tool_summary(block["input"]))}

    data =
      case tool_input(name, block["input"]) do
        nil -> Map.put(data, "arguments", json(block["input"]))
        input -> Map.put(data, "input", input)
      end

    [event("tool_use", data)]
  end

  defp assistant_block(_block, _line), do: []

  defp user_block(%{"type" => "tool_result"} = block, decisions) do
    data = %{
      "tool_use_id" => block["tool_use_id"],
      "text" => truncate(result_text(block["content"])),
      "is_error" => block["is_error"] == true
    }

    data =
      case decisions[block["tool_use_id"]] do
        nil -> data
        decision -> Map.put(data, "decision", decision)
      end

    [event("tool_result", data)]
  end

  defp user_block(_block, _decisions), do: []

  # The permission decisions of the calls a user line answers, by call id.
  defp decisions(meta) when is_list(meta) do
    for %{"id" => id, "permission_decision" => %{} = decision} <- meta, into: %{} do
      {id, %{"decision" => decision["decision"], "source" => decision["source"]}}
    end
  end

  defp decisions(_meta), do: %{}

  defp put_parent(event, parent) when is_binary(parent),
    do: %{event | data: Map.put(event.data, "parent_tool_use_id", parent)}

  defp put_parent(event, _parent), do: event

  defp tool_input(name, input) when is_map(input) and is_map_key(@tool_inputs, name) do
    for key <- @tool_inputs[name], value = input_value(key, input[key]), into: %{} do
      {key, value}
    end
  end

  defp tool_input(_name, _input), do: nil

  defp input_value("todos", todos) when is_list(todos) do
    for %{"content" => content, "status" => status} <- Enum.take(todos, @max_todos),
        do: %{"content" => truncate(content, @max_input_bytes), "status" => status}
  end

  defp input_value(_key, value) when is_binary(value), do: truncate(value, @max_input_bytes)
  defp input_value(_key, value) when is_number(value), do: value
  defp input_value(_key, _value), do: nil

  defp tool_summary(input) when is_map(input) do
    Enum.find_value(@tool_summary_keys, fn key ->
      case input[key] do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end) || json(input)
  end

  defp tool_summary(_input), do: ""

  defp result_text(text) when is_binary(text), do: text

  # Text parts are kept; other parts (images, tool references) only say what
  # they are, grouped: "[tool_reference ×10]".
  defp result_text(parts) when is_list(parts) do
    texts = for %{"type" => "text", "text" => text} <- parts, do: text

    others =
      for %{"type" => type} <- parts, type != "text" do
        type
      end
      |> Enum.frequencies()
      |> Enum.sort()
      |> Enum.map(fn
        {type, 1} -> "[#{type}]"
        {type, count} -> "[#{type} ×#{count}]"
      end)

    Enum.join(texts ++ others, "\n")
  end

  defp result_text(_content), do: ""

  # ── Small values ──────────────────────────────────────────────────────────

  # The names in one of the init's lists (plain names or maps with "name").
  defp names(list) when is_list(list) do
    for item <- Enum.take(list, @max_list),
        name = if(is_map(item), do: item["name"], else: item),
        is_binary(name),
        do: short(name)
  end

  defp names(_list), do: []

  defp entries(list, keys) when is_list(list) do
    for %{} = item <- Enum.take(list, @max_list) do
      for key <- keys, value = item[key], is_binary(value), into: %{}, do: {key, short(value)}
    end
  end

  defp entries(_list, _keys), do: []

  defp json(nil), do: ""

  defp json(value) do
    value |> JSON.encode!() |> truncate(@max_input_bytes)
  rescue
    _not_json -> truncate(inspect(value, limit: 50), @max_input_bytes)
  end

  defp short(value) when is_binary(value), do: truncate(value, @max_name_bytes)
  defp short(nil), do: nil
  defp short(value), do: value |> inspect(limit: 10) |> truncate(@max_name_bytes)

  defp truncate(text, max \\ @max_text_bytes), do: Text.truncate(text, max)

  defp event(type, data), do: %__MODULE__{type: type, data: data}
end
