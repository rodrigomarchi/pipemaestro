defmodule ClaudeControlPlaneProtocol.JobEvent do
  @moduledoc """
  One event of a running job, as the runner reports it.

  The agent CLI (`claude -p --output-format stream-json`) prints one JSON object
  per line, most of them large and internal (session metadata, token counters,
  signatures). `from_stream_json/1` reduces a line to the few events worth
  showing, each with a small `data` map whose texts are cut at
  `max_text_bytes/0`:

    * `"system"` — the session started: `text`, `model`, `cwd`, `version`.
    * `"assistant_text"` — something the agent said: `text`.
    * `"tool_use"` — a tool call: `name`, `text` (its main argument).
    * `"tool_result"` — a tool's answer: `text`, `is_error`.
    * `"result"` — the run ended: `text`, `is_error`, `cost_usd`,
      `duration_ms`, `num_turns`.
  """

  @enforce_keys [:type, :data]
  defstruct @enforce_keys

  @type t :: %__MODULE__{type: String.t(), data: %{String.t() => term()}}

  @types ~w(system assistant_text tool_use tool_result result)
  @max_text_bytes 8_000

  # The tool argument worth showing, in order of preference.
  @tool_summary_keys ~w(command file_path pattern url query description prompt)

  @doc "Every event type, as sent on the wire."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The longest text an event carries, in bytes."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc "The events in one decoded `stream-json` line; lines nobody needs give `[]`."
  @spec from_stream_json(map()) :: [t()]
  def from_stream_json(%{"type" => "system", "subtype" => "init"} = line) do
    model = line["model"] || "?"

    [
      event("system", %{
        "text" => "Sessão iniciada (#{model})",
        "model" => model,
        "cwd" => line["cwd"],
        "version" => line["claude_code_version"]
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
        "num_turns" => line["num_turns"]
      })
    ]
  end

  def from_stream_json(_line), do: []

  @doc "The wire form, without the job id and sequence the runner adds."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{type: type, data: data}), do: %{"type" => type, "data" => data}

  defp assistant_block(%{"type" => "text", "text" => text}) when text != "",
    do: [event("assistant_text", %{"text" => truncate(text)})]

  defp assistant_block(%{"type" => "tool_use", "name" => name} = block),
    do: [event("tool_use", %{"name" => name, "text" => truncate(tool_summary(block["input"]))})]

  defp assistant_block(_block), do: []

  defp user_block(%{"type" => "tool_result"} = block) do
    [
      event("tool_result", %{
        "text" => truncate(result_text(block["content"])),
        "is_error" => block["is_error"] == true
      })
    ]
  end

  defp user_block(_block), do: []

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

  defp result_text(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => type} -> "[#{type}]"
      _other -> ""
    end)
    |> Enum.join("\n")
  end

  defp result_text(_content), do: ""

  defp truncate(text) when byte_size(text) <= @max_text_bytes, do: text

  # Cuts at a byte count, dropping a UTF-8 character split by the cut, and
  # leaves room for the ellipsis (3 bytes).
  defp truncate(text) do
    <<head::binary-size(@max_text_bytes - 3), _rest::binary>> = text

    valid =
      case :unicode.characters_to_binary(head) do
        binary when is_binary(binary) -> binary
        {_incomplete_or_error, valid, _rest} -> valid
      end

    valid <> "…"
  end

  defp event(type, data), do: %__MODULE__{type: type, data: data}
end
