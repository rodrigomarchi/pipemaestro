defmodule PipeMaestroProtocol.RunnerLog do
  @moduledoc """
  The runner's own log (ADR 0039), on the runner's channel.

  Runner → control plane, from a runner that announces the `"logs"`
  capability, through the outbox (dropped first, like a job's events, when
  it fills up):

    * `"runner:log"` — `%{"lines"}`: up to `max_lines/0` lines
      `%{"at", "level", "message", "event", "attrs"}`, oldest first. `at` is
      an ISO 8601 timestamp, `level` one of `levels/0`, `message` at most
      `max_message_bytes/0`, its secrets already redacted on the runner. A
      line about something that happened to the runner itself names it in
      `event`, one of `events/0`, with plain values in `attrs`; any other
      line has neither.

  With `"logs": false` in the join's reply (`telemetry_reply/1`), the
  runner sends only the lines that have an `event`.
  """

  alias PipeMaestroProtocol.Text

  @levels ~w(debug info warning error)
  @events ~w(update_applied update_failed update_draining scratch_remove_failed outbox_dropped
             connection_lost log_dropped)

  @max_lines 200
  @max_message_bytes 4_096
  @max_attrs 20
  @max_attr_bytes 1_000

  @doc "The message's name."
  @spec event() :: String.t()
  def event, do: "runner:log"

  @doc "The most lines one message carries."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc "The longest line's message, in bytes."
  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message_bytes

  @doc "The levels of a line."
  @spec levels() :: [String.t()]
  def levels, do: @levels

  @doc "What a line may say happened to the runner (`event`)."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc """
  What the join's reply says about the runner's telemetry: whether the
  workspace keeps its log lines (`"logs"`).
  """
  @spec telemetry_reply(boolean()) :: map()
  def telemetry_reply(logs?), do: %{"logs" => logs?}

  @doc """
  Whether the join's `reply` asks for the log lines; a control plane that
  does not say keeps them.
  """
  @spec logs?(map()) :: boolean()
  def logs?(%{"telemetry" => %{"logs" => false}}), do: false
  def logs?(_reply), do: true

  @doc """
  A line as of `at` (a `DateTime`), its message cut to
  `max_message_bytes/0`; with `event` (one of `events/0`), the event and
  its plain attributes.
  """
  @spec line(DateTime.t(), String.t(), String.t(), String.t() | nil, map()) :: map()
  def line(%DateTime{} = at, level, message, event \\ nil, attrs \\ %{})
      when level in @levels do
    base = %{
      "at" => DateTime.to_iso8601(at),
      "level" => level,
      "message" => Text.truncate(message, @max_message_bytes)
    }

    if event in @events,
      do: Map.merge(base, %{"event" => event, "attrs" => plain(attrs)}),
      else: base
  end

  @doc """
  Validates a `runner:log` payload: returns its lines with `at` as a
  `DateTime`, an unknown `event` dropped and the attributes kept plain.
  """
  @spec parse(term()) :: {:ok, [map()]} | {:error, String.t()}
  def parse(%{"lines" => lines}) when is_list(lines) and length(lines) <= @max_lines do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case parse_line(line) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  def parse(%{"lines" => lines}) when is_list(lines),
    do: {:error, "at most #{@max_lines} lines a message"}

  def parse(_payload), do: {:error, "a log message needs lines"}

  defp parse_line(%{"at" => at, "level" => level, "message" => message} = line)
       when is_binary(at) and level in @levels and is_binary(message) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} ->
        event = if line["event"] in @events, do: line["event"]

        {:ok,
         %{
           "at" => at,
           "level" => level,
           "message" => Text.truncate(message, @max_message_bytes),
           "event" => event,
           "attrs" => if(event, do: plain(line["attrs"]), else: %{})
         }}

      {:error, _reason} ->
        {:error, "at must be an ISO 8601 timestamp"}
    end
  end

  defp parse_line(_line), do: {:error, "each line needs at, a level and a message"}

  defp plain(attrs) when is_map(attrs) do
    attrs
    |> Enum.take(@max_attrs)
    |> Enum.flat_map(fn {key, value} ->
      case value do
        v when is_binary(v) -> [{to_string(key), Text.truncate(v, @max_attr_bytes)}]
        v when is_number(v) or is_boolean(v) -> [{to_string(key), v}]
        v when is_atom(v) and not is_nil(v) -> [{to_string(key), Atom.to_string(v)}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp plain(_attrs), do: %{}
end
