defmodule PipeMaestroProtocol.Telemetry do
  @moduledoc """
  What the agent CLI's OpenTelemetry reports about a job, as the runner relays
  it: `"job:telemetry"` — `%{"job_id", "records"}`, at most `max_records/0`
  records per message, each `record/3`: `%{"name", "at", "attrs"}`.

  The runner receives the CLI's OTLP export on the machine itself and keeps
  the events and metrics in `names/0`:

    * `"api_request"` — one call to the model: `model`, `duration_ms`,
      `ttft_ms`, the tokens (`input_tokens`, `output_tokens`,
      `cache_read_tokens`, `cache_creation_tokens`), `cost_usd`, `request_id`.
    * `"api_error"`, `"api_refusal"` — a call that failed or was refused:
      `error`, `status_code`, `attempt`, `category`.
    * `"tool_result"` — a tool ran: `tool_name`, `tool_use_id`, `success`,
      `duration_ms`, `error`, the input and result sizes.
    * `"tool_decision"` — a tool was allowed or refused: `decision`
      (`accept`/`reject`), `source`, `permission_mode`.
    * `"mcp_server_connection"` — an MCP server connected or not: `status`,
      `transport_type`, `server_scope`, `duration_ms`.
    * `"subagent_completed"` — a subagent ended.
    * `"metric:<name>"` — a metric's increment over the export interval
      (`value`): `lines_of_code` (by `type`, added or removed), `commit`,
      `pull_request` and `active_time` (seconds).

  Only the attributes in `attrs/0` are kept, plain values only, texts cut at
  1 000 bytes: nothing that names the person (e-mail, account) leaves the
  runner, and the contents of prompts and answers are not part of it (the
  events carry them).
  """

  alias PipeMaestroProtocol.Text

  @names ~w(api_request api_error api_refusal tool_result tool_decision
            mcp_server_connection subagent_completed
            metric:lines_of_code metric:commit metric:pull_request metric:active_time)

  @numbers ~w(cost_usd duration_ms ttft_ms input_tokens output_tokens cache_read_tokens
              cache_creation_tokens status_code attempt tool_input_size_bytes
              tool_result_size_bytes value)

  @booleans ~w(success)

  @texts ~w(model request_id speed query_source effort error error_type category
            tool_name tool_use_id decision source decision_type decision_source tool_source
            permission_mode mcp_server_scope status transport_type server_scope
            agent_type type prompt.id)

  @max_records 200
  @max_text_bytes 1_000

  @doc "The message's name."
  @spec event() :: String.t()
  def event, do: "job:telemetry"

  @doc "The most records one message carries."
  @spec max_records() :: pos_integer()
  def max_records, do: @max_records

  @doc "The record names kept."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The attributes kept."
  @spec attrs() :: [String.t()]
  def attrs, do: @numbers ++ @booleans ++ @texts

  @doc """
  A record of `name` at `at` (an ISO 8601 timestamp) with the attributes
  worth keeping; `nil` for a name not in `names/0`.
  """
  @spec record(String.t(), String.t(), map()) :: map() | nil
  def record(name, at, attrs) when name in @names do
    # A false is kept: only what normalizes to nil goes.
    kept =
      Enum.reduce(attrs, %{}, fn {key, value}, kept ->
        case normalize(key, value) do
          nil -> kept
          normalized -> Map.put(kept, key, normalized)
        end
      end)

    %{"name" => name, "at" => at, "attrs" => kept}
  end

  def record(_name, _at, _attrs), do: nil

  defp normalize(key, value) when key in @numbers, do: number(value)
  defp normalize(key, value) when key in @booleans, do: boolean(value)
  defp normalize(key, value) when key in @texts and is_binary(value), do: cut(value)
  defp normalize(key, value) when key in @texts and is_number(value), do: to_string(value)
  defp normalize(_key, _value), do: nil

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        integer

      _not_integer ->
        case Float.parse(value) do
          {float, ""} -> float
          _neither -> nil
        end
    end
  end

  defp number(_value), do: nil

  defp boolean(value) when is_boolean(value), do: value
  defp boolean("true"), do: true
  defp boolean("false"), do: false
  defp boolean(_value), do: nil

  defp cut(text), do: Text.truncate(text, @max_text_bytes)
end
