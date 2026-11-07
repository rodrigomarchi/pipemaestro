defmodule PipeMaestroProtocol.RunnerDoctor do
  @moduledoc """
  The runner's diagnosis (its `doctor`, ADR 0039), on the runner's channel,
  between a control plane and a runner that announces the `"doctor"`
  capability.

  Control plane → runner:

    * `"runner:doctor"` — `%{"request_id"}`: run the diagnosis now.

  Runner → control plane, after every join, every `interval_ms/0` and in
  answer to a request (with its `request_id`), outside the outbox:

    * `"runner:doctor"` — `%{"request_id", "at", "checks"}`: `checks` is a
      list of `%{"key", "name", "status", "detail"}`, `status` one of
      `statuses/0`, `key` the check's stable name.
  """

  alias PipeMaestroProtocol.Text

  @statuses ~w(ok warning error)
  @interval_ms 3_600_000
  @max_checks 40
  @key_format ~r/^[a-z0-9_]{1,40}$/

  @doc "The message's name, in both directions."
  @spec event() :: String.t()
  def event, do: "runner:doctor"

  @doc "How often the runner runs it on its own."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval_ms

  @doc "A check's statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  The wire form of a diagnosis taken at `at`, from the runner's checks
  (`%{key, name, status, detail}` with an atom status), answering
  `request_id` (or `nil`).
  """
  @spec to_map([map()], DateTime.t(), String.t() | nil) :: map()
  def to_map(checks, %DateTime{} = at, request_id \\ nil) do
    %{
      "request_id" => request_id,
      "at" => DateTime.to_iso8601(at),
      "checks" =>
        for check <- checks do
          %{
            "key" => check.key,
            "name" => check.name,
            "status" => to_string(check.status),
            "detail" => check.detail
          }
        end
    }
  end

  @doc """
  Validates a diagnosis: `at` as a `DateTime`, at most #{@max_checks} checks,
  each with a key, a name, a known status and a detail (cut at 1 000 bytes).
  """
  @spec parse(term()) :: {:ok, map()} | {:error, String.t()}
  def parse(%{"at" => at, "checks" => checks} = payload)
      when is_binary(at) and is_list(checks) and length(checks) <= @max_checks do
    with {:ok, at, _offset} <- DateTime.from_iso8601(at),
         {:ok, checks} <- checks(checks) do
      request_id = if is_binary(payload["request_id"]), do: payload["request_id"]
      {:ok, %{"request_id" => request_id, "at" => at, "checks" => checks}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _bad_time -> {:error, "at must be an ISO 8601 timestamp"}
    end
  end

  def parse(_payload), do: {:error, "a diagnosis needs at and its checks"}

  defp checks(checks) do
    Enum.reduce_while(checks, {:ok, []}, fn
      %{"key" => key, "name" => name, "status" => status, "detail" => detail}, {:ok, acc}
      when is_binary(key) and is_binary(name) and status in @statuses and is_binary(detail) ->
        if key =~ @key_format do
          check = %{
            "key" => key,
            "name" => Text.truncate(name, 80),
            "status" => status,
            "detail" => Text.truncate(detail, 1_000)
          }

          {:cont, {:ok, [check | acc]}}
        else
          {:halt, {:error, "a check's key must be lowercase letters, digits or _"}}
        end

      _bad, _acc ->
        {:halt, {:error, "each check needs a key, a name, a status and a detail"}}
    end)
    |> case do
      {:ok, checks} -> {:ok, Enum.reverse(checks)}
      error -> error
    end
  end
end
