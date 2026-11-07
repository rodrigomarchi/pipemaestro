defmodule PipeMaestroRunner.Connection.Keeper do
  @moduledoc """
  Keeps a `PipeMaestroRunner.Connection` running: starts it with the options
  it is given and, when it crashes or stops for a reason reconnecting can
  help with, starts another after a backoff (500 ms up to 30 s; back to the
  start once a connection lived a minute), with no limit.

  A connection that stops normally ended on purpose (the platform refused
  the runner, or it drained before an update): it already told `:notify`,
  and none is started again. A crash is told to `:notify` as
  `{:runner_connection, {:disconnected, {:crashed, reason}}}`.
  """
  use GenServer

  require Logger

  alias PipeMaestroRunner.Connection

  @backoff [500, 1_000, 2_000, 5_000, 10_000, 30_000]
  @steady_ms 60_000

  @doc "Starts the keeper and its first connection; `opts` are the connection's."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The connection running now, or `nil` while waiting to start another."
  @spec connection(GenServer.server()) :: pid() | nil
  def connection(keeper), do: GenServer.call(keeper, :connection)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, start_connection(%{opts: opts, connection: nil, started_at: nil, failures: 0})}
  end

  @impl true
  def handle_call(:connection, _from, state), do: {:reply, state.connection, state}

  @impl true
  def handle_info({:EXIT, pid, :normal}, %{connection: pid} = state),
    do: {:noreply, %{state | connection: nil}}

  def handle_info({:EXIT, pid, reason}, %{connection: pid} = state) do
    Logger.warning("A conexão com a plataforma caiu: #{inspect(reason, limit: 5)}. Reiniciando.")
    notify(state, {:disconnected, {:crashed, reason}})
    {:noreply, retry(%{state | connection: nil})}
  end

  # A task of the connection that ended after it, or a link of its own.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:start, state), do: {:noreply, start_connection(state)}

  defp start_connection(state) do
    case Connection.start_link(state.opts) do
      {:ok, pid} ->
        %{state | connection: pid, started_at: System.monotonic_time(:millisecond)}

      {:error, reason} ->
        Logger.warning("A conexão com a plataforma não subiu: #{inspect(reason, limit: 5)}.")
        retry(state)
    end
  end

  defp retry(state) do
    lived = state.started_at && System.monotonic_time(:millisecond) - state.started_at
    failures = if lived && lived >= @steady_ms, do: 0, else: state.failures
    Process.send_after(self(), :start, Enum.at(@backoff, failures, List.last(@backoff)))
    %{state | failures: failures + 1, started_at: nil}
  end

  defp notify(%{opts: opts}, event) do
    case Keyword.get(opts, :notify) do
      pid when is_pid(pid) -> send(pid, {:runner_connection, event})
      _none -> :ok
    end
  end
end
