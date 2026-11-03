defmodule ClaudeControlPlaneProtocol.JobEvent do
  @moduledoc """
  One event of a running job, as the runner reports it.

  The agent CLI (`claude -p --output-format stream-json`) prints one JSON object
  per line, most of them large and internal (session metadata, token counters,
  signatures). `from_stream_json/1` reduces a line to the few events worth
  showing, each with a small `data` map whose texts are cut at
  `max_text_bytes/0`:

    * `"system"` — the session started: `text`, `model`, `cwd`, `version`,
      `auth` (the CLI's `apiKeySource`: `"none"` for a signed-in user's
      login, else the API key's source) and `permission_mode`.
    * `"assistant_text"` — something the agent said: `text`.
    * `"tool_use"` — a tool call: `id`, `name`, `text` (its main argument)
      and, for the tools the screens know, `input`: the arguments worth
      showing (`tool_inputs/0`), texts cut at `max_input_bytes/0`.
    * `"tool_result"` — a tool's answer: `tool_use_id`, `text`, `is_error`.
    * `"result"` — the run ended: `text`, `is_error`, `cost_usd`,
      `duration_ms`, `num_turns` and, when the run was given a JSON Schema,
      `structured_output`.
  """

  @enforce_keys [:type, :data]
  defstruct @enforce_keys

  @type t :: %__MODULE__{type: String.t(), data: %{String.t() => term()}}

  @types ~w(system assistant_text tool_use tool_result result)
  @max_text_bytes 8_000
  @max_input_bytes 4_000
  @max_todos 50

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

  @doc "The longest text in a tool call's `input`, in bytes."
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
        "model" => model,
        "cwd" => line["cwd"],
        "version" => line["claude_code_version"],
        "auth" => line["apiKeySource"],
        "permission_mode" => line["permissionMode"]
      })
    ]
  end

  def from_stream_json(%{"type" => "assistant", "message" => %{"content" => content}})
      when is_list(content),
      do: Enum.flat_map(content, &assistant_block/1)

  def from_stream_json(%{"type" => "user", "message" => %{"content" => content}})
      when is_list(content),
      do: Enum.flat_map(content, &user_block/1)

  def from_stream_json(%{"type" => "result"} = line) do
    [
      event("result", %{
        "text" => truncate(line["result"] || line["subtype"] || ""),
        "is_error" => line["is_error"] == true,
        "cost_usd" => line["total_cost_usd"],
        "duration_ms" => line["duration_ms"],
        "num_turns" => line["num_turns"],
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

  defp assistant_block(%{"type" => "text", "text" => text}) when text != "",
    do: [event("assistant_text", %{"text" => truncate(text)})]

  defp assistant_block(%{"type" => "tool_use", "name" => name} = block) do
    data =
      %{"id" => block["id"], "name" => name, "text" => truncate(tool_summary(block["input"]))}

    data =
      case tool_input(name, block["input"]) do
        nil -> data
        input -> Map.put(data, "input", input)
      end

    [event("tool_use", data)]
  end

  defp assistant_block(_block), do: []

  defp user_block(%{"type" => "tool_result"} = block) do
    [
      event("tool_result", %{
        "tool_use_id" => block["tool_use_id"],
        "text" => truncate(result_text(block["content"])),
        "is_error" => block["is_error"] == true
      })
    ]
  end

  defp user_block(_block), do: []

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
    end) || inspect(input, limit: 10, printable_limit: 200)
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

  defp truncate(text, max \\ @max_text_bytes)

  defp truncate(text, max) when byte_size(text) <= max, do: text

  # Cuts at a byte count, dropping a UTF-8 character split by the cut, and
  # leaves room for the ellipsis (3 bytes).
  defp truncate(text, max) do
    keep = max - 3
    <<head::binary-size(^keep), _rest::binary>> = text

    valid =
      case :unicode.characters_to_binary(head) do
        binary when is_binary(binary) -> binary
        {_incomplete_or_error, valid, _rest} -> valid
      end

    valid <> "…"
  end

  defp event(type, data), do: %__MODULE__{type: type, data: data}
end
