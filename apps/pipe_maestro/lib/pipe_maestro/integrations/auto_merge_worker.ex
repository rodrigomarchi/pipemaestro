defmodule PipeMaestro.Integrations.AutoMergeWorker do
  @moduledoc """
  Looks, every `:every` ms (a minute by default), at the pull requests of the
  tasks waiting for their checks to merge them
  (`PipeMaestro.Integrations.AutoMerge.check/2`). A change of such a task
  looks at once (`PipeMaestro.Integrations.FeedbackWorker`); this catches the
  checks that end on the host with nothing changing on the platform.
  """
  use GenServer

  require Logger

  alias PipeMaestro.Integrations
  alias PipeMaestro.Integrations.AutoMerge

  @doc "Starts the worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Looks at every task waiting; answers how many it started to look at."
  @spec run() :: non_neg_integer()
  def run do
    AutoMerge.waiting_task_ids()
    |> Enum.count(&(Integrations.background(fn -> AutoMerge.check(&1) end) != :busy))
  end

  @impl true
  def init(opts) do
    every = Keyword.get(opts, :every, :timer.minutes(1))
    Process.send_after(self(), :run, every)
    {:ok, %{every: every}}
  end

  @impl true
  def handle_info(:run, state) do
    try do
      _started = run()
    rescue
      exception -> Logger.error(Exception.format(:error, exception, __STACKTRACE__))
    end

    Process.send_after(self(), :run, state.every)
    {:noreply, state}
  end
end
