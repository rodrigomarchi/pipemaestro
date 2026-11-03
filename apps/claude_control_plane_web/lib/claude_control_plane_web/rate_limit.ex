defmodule ClaudeControlPlaneWeb.RateLimit do
  @moduledoc """
  A fixed-window request counter per key (an address and what it asks for),
  kept in ETS on this node. Enough to keep one machine from flooding the
  runner sign-in; with several nodes each counts its own.
  """
  use GenServer

  @table __MODULE__

  @doc "Starts the owner of the counters table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one more request for `key`: `:ok` while within `limit` requests per
  `window_ms`, else `{:error, retry_after_seconds}`.
  """
  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | {:error, pos_integer()}
  def hit(key, limit, window_ms) do
    # Monotonic time may be negative: floor_div keeps the windows aligned.
    now = System.monotonic_time(:millisecond)
    started = Integer.floor_div(now, window_ms) * window_ms
    count = :ets.update_counter(@table, {key, started}, 1, {{key, started}, 0})

    if count <= limit,
      do: :ok,
      else: {:error, max(1, div(started + window_ms - now + 999, 1000))}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  # Old windows are dropped every few minutes.
  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", div(now, 3_600_000) - 1}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.minutes(5))
end
