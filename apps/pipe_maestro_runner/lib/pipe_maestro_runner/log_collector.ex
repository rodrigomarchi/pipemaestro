defmodule PipeMaestroRunner.LogCollector do
  @moduledoc """
  Collects the runner's log for the control plane (ADR 0039,
  `PipeMaestroProtocol.RunnerLog`): what goes through the Logger (a
  `:logger` handler, `install_handler/0`) and what the commands write to
  the terminal (`PipeMaestroRunner.Output`, `capture/3`).

    * **Secrets never leave the machine.** Every value it was told about
      (the runner's token and API key when it starts, each job's secrets and
      git credential while the job runs, `add_secrets/2`) becomes
      `[redigido]` in the lines.
    * **Batches.** Lines go to the sink (the connection, `attach/2`) as
      `{:runner_log, lines}`, at most `PipeMaestroProtocol.RunnerLog.max_lines/0`
      at a time, every `:flush_every` ms (default 5 s) or as soon as a batch
      is full. Without a sink, it keeps the last `:keep` lines (default 2 000)
      for when one comes.
    * **A ceiling.** At most `:per_minute` lines a minute (default 1 000);
      the rest are counted, and a `log_dropped` line says how many.
    * **Events only**, when the sink asks (`attach(sink, false)`): the
      workspace keeps no log lines, so only the lines about something that
      happened to the runner (`event`) go.

  A Logger call marks such a line with the metadata `runner_event` (one of
  `PipeMaestroProtocol.RunnerLog.events/0`) and `event_attrs` (a map).

  Every function is a no-op when the collector is not running: only
  `runner.start` starts it.
  """
  use GenServer

  alias PipeMaestroProtocol.RunnerLog

  @handler_id :pipemaestro_log_collector
  @redacted "[redigido]"
  # Shorter values would redact ordinary words.
  @min_secret_bytes 6

  @doc "Starts the collector. Options: `:secrets`, `:flush_every`, `:keep`, `:per_minute`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sends what goes through the Logger, from `:info` up, to the collector."
  @spec install_handler() :: :ok | {:error, term()}
  def install_handler do
    case :logger.add_handler(@handler_id, __MODULE__.Handler, %{level: :info}) do
      :ok -> :ok
      {:error, {:already_exist, @handler_id}} -> :ok
      error -> error
    end
  end

  @doc "Stops sending the Logger's events to the collector."
  @spec remove_handler() :: :ok | {:error, term()}
  def remove_handler, do: :logger.remove_handler(@handler_id)

  @doc """
  Collects a line at `level` (`:debug`, `:info`, `:warning` or `:error`);
  with `event` in `meta`, a line about something that happened to the runner.
  """
  @spec capture(atom(), String.t(), map()) :: :ok
  def capture(level, message, meta \\ %{}) do
    cast({:capture, DateTime.utc_now(), level(level), message, meta})
  end

  @doc "Values to redact while `key` (a job id) lasts."
  @spec add_secrets(term(), [String.t()]) :: :ok
  def add_secrets(key, values), do: cast({:add_secrets, key, values})

  @doc "Stops redacting the values of `key`."
  @spec forget_secrets(term()) :: :ok
  def forget_secrets(key), do: cast({:forget_secrets, key})

  @doc """
  Sends the lines to `sink` from now on, all of them or, with `logs?`
  false, only the events.
  """
  @spec attach(pid(), boolean()) :: :ok
  def attach(sink, logs? \\ true), do: cast({:attach, sink, logs?})

  @doc "Sends what it holds to the sink now (for tests)."
  @spec flush() :: :ok
  def flush do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :flush), else: :ok
  end

  defp cast(message) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, message)
    :ok
  end

  defp level(level) when level in [:debug, :info, :warning, :error], do: Atom.to_string(level)
  defp level(level) when level in [:notice], do: "info"
  defp level(level) when level in [:critical, :alert, :emergency], do: "error"
  defp level(level) when level in [:warn], do: "warning"
  defp level(_level), do: "info"

  @impl true
  def init(opts) do
    every = Keyword.get(opts, :flush_every, 5_000)
    Process.send_after(self(), :flush, every)

    {:ok,
     %{
       lines: [],
       count: 0,
       sink: nil,
       logs?: true,
       keep: Keyword.get(opts, :keep, 2_000),
       flush_every: every,
       per_minute: Keyword.get(opts, :per_minute, 1_000),
       minute: nil,
       in_minute: 0,
       dropped: 0,
       secrets: %{static: secrets(Keyword.get(opts, :secrets, []))}
     }}
  end

  @impl true
  def handle_cast({:capture, at, level, message, meta}, state) do
    minute = div(DateTime.to_unix(at), 60)
    state = roll_minute(state, minute, at)

    if state.in_minute >= state.per_minute do
      {:noreply, %{state | dropped: state.dropped + 1}}
    else
      line =
        RunnerLog.line(
          at,
          level,
          redact(to_text(message), state),
          meta_value(meta, :runner_event),
          meta_value(meta, :event_attrs) || %{}
        )

      {:noreply, state |> Map.update!(:in_minute, &(&1 + 1)) |> push(line) |> flush_if_full()}
    end
  end

  def handle_cast({:add_secrets, key, values}, state),
    do: {:noreply, put_in(state, [:secrets, key], secrets(values))}

  def handle_cast({:forget_secrets, key}, state),
    do: {:noreply, %{state | secrets: Map.delete(state.secrets, key)}}

  def handle_cast({:attach, sink, logs?}, state),
    do: {:noreply, flush_out(%{state | sink: sink, logs?: logs?})}

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, flush_out(state)}

  @impl true
  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, state.flush_every)
    {:noreply, flush_out(state)}
  end

  # A new minute: the count starts over, and the lines dropped in the last
  # one are told.
  defp roll_minute(%{minute: minute} = state, minute, _at), do: state

  defp roll_minute(state, minute, at) do
    state = %{state | minute: minute, in_minute: 0}

    if state.dropped > 0 do
      line =
        RunnerLog.line(
          at,
          "warning",
          "#{state.dropped} linhas do log descartadas: mais de #{state.per_minute} por minuto.",
          "log_dropped",
          %{"count" => state.dropped}
        )

      state |> Map.put(:dropped, 0) |> push(line)
    else
      state
    end
  end

  defp push(state, line) do
    lines = [line | state.lines]

    # Without a sink, only the latest lines are kept.
    if state.sink == nil and state.count >= state.keep,
      do: %{state | lines: Enum.take(lines, state.keep)},
      else: %{state | lines: lines, count: state.count + 1}
  end

  defp flush_if_full(state) do
    if state.sink && state.count >= RunnerLog.max_lines(), do: flush_out(state), else: state
  end

  defp flush_out(%{sink: nil} = state), do: state
  defp flush_out(%{lines: []} = state), do: state

  defp flush_out(state) do
    lines = Enum.reverse(state.lines)
    lines = if state.logs?, do: lines, else: Enum.filter(lines, &Map.has_key?(&1, "event"))

    lines
    |> Enum.chunk_every(RunnerLog.max_lines())
    |> Enum.each(&send(state.sink, {:runner_log, &1}))

    %{state | lines: [], count: 0}
  end

  defp secrets(values) do
    values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_secret_bytes))
    |> Enum.uniq()
  end

  defp redact(text, state) do
    state.secrets
    |> Map.values()
    |> List.flatten()
    # The longest first: a secret that contains another goes whole.
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(text, &String.replace(&2, &1, @redacted))
  end

  defp to_text(message) when is_binary(message), do: message

  defp to_text(message) do
    IO.chardata_to_string(message)
  rescue
    _not_chardata -> inspect(message)
  end

  defp meta_value(meta, key) when is_map(meta), do: Map.get(meta, key)
  defp meta_value(_meta, _key), do: nil
end
