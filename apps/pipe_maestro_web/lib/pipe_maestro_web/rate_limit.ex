defmodule PipeMaestroWeb.RateLimit do
  @moduledoc """
  A fixed-window request counter per key (an address and what it asks for),
  kept in ETS on this node. Enough to keep one machine from flooding the
  runner sign-in, the sign-in form or the sign-up (ADR 0058); with several
  nodes each counts its own.
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

    count =
      :ets.update_counter(
        @table,
        {key, started},
        {2, 1},
        {{key, started}, 0, started + window_ms}
      )

    if count <= limit,
      do: :ok,
      else: {:error, max(1, div(started + window_ms - now + 999, 1000))}
  end

  @doc """
  Counts one more request for `key` against the limit named `name` in the
  `:rate_limits` configuration (`{limit, window_ms}`).
  """
  @spec check(atom(), term()) :: :ok | {:error, pos_integer()}
  def check(name, key) do
    {limit, window_ms} =
      Keyword.fetch!(Application.fetch_env!(:pipe_maestro_web, :rate_limits), name)

    hit({name, key}, limit, window_ms)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  # Every few minutes, the windows that already ended are dropped. Each entry
  # is `{{key, started}, count, ends_at}`, in monotonic milliseconds.
  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.minutes(5))
end
