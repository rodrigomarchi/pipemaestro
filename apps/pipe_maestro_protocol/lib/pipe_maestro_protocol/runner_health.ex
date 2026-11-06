defmodule PipeMaestroProtocol.RunnerHealth do
  @moduledoc """
  How the runner's machine is doing (ADR 0039), on the runner's channel.

  Runner → control plane, from a runner that announces the `"health"`
  capability, after joining and every `interval_ms/0`, outside the outbox:

    * `"runner:health"` — `%{"at", "cpu_pct", "load1", "mem_used_bytes",
      "mem_total_bytes", "disk_free_bytes", "disk_total_bytes",
      "outbox_pending", "running_jobs", "beam_bytes"}`: `at` an ISO 8601
      timestamp, the rest numbers, any of them `nil` when the machine does
      not tell. `cpu_pct` is the whole machine's (0–100), `load1` the load
      average of the last minute, the disk is the one of the runner's
      working directory and `beam_bytes` the memory of the runner's own VM.
  """

  @fields ~w(cpu_pct load1 mem_used_bytes mem_total_bytes disk_free_bytes disk_total_bytes
             outbox_pending running_jobs beam_bytes)

  @interval_ms 60_000

  @doc "The message's name."
  @spec event() :: String.t()
  def event, do: "runner:health"

  @doc "How often the runner sends it."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval_ms

  @doc "The measured fields, all numbers or `nil`."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc """
  Validates a sample: `at` must be a timestamp and every field a
  non-negative number or `nil` (a missing one counts as `nil`). Returns the
  sample with `at` as a `DateTime` and only the known fields.
  """
  @spec parse(term()) :: {:ok, map()} | {:error, String.t()}
  def parse(%{"at" => at} = payload) when is_binary(at) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(at),
         {:ok, values} <- values(payload) do
      {:ok, Map.put(values, "at", at)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _reason} -> {:error, "at must be an ISO 8601 timestamp"}
    end
  end

  def parse(_payload), do: {:error, "a health sample needs at"}

  defp values(payload) do
    Enum.reduce_while(@fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.get(payload, field) do
        nil -> {:cont, {:ok, Map.put(acc, field, nil)}}
        n when is_number(n) and n >= 0 -> {:cont, {:ok, Map.put(acc, field, n)}}
        _other -> {:halt, {:error, "#{field} must be a non-negative number or null"}}
      end
    end)
  end
end
