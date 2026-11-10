defmodule PipeMaestro.Integrations.FeedbackWorker do
  @moduledoc """
  Reflects each change of a task that came from a linked repository on its
  git host (`PipeMaestro.Integrations.Feedback.sync/1`), in the background:
  it listens to `PipeMaestro.Tasks.subscribe(:linked)`. A sync that fails is
  left for the reconciliation (`PipeMaestro.Integrations.Reconciler`). A task
  waiting to merge its pull request is then looked at
  (`PipeMaestro.Integrations.AutoMerge.check/2`), and the commits of a
  delivered pull request read (`PipeMaestro.Integrations.PrOutcomes.observe/1`).
  """
  use GenServer

  alias PipeMaestro.Integrations
  alias PipeMaestro.Integrations.{AutoMerge, Feedback, PrOutcomes}
  alias PipeMaestro.Tasks

  @doc "Starts the worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = Tasks.subscribe(:linked)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:linked_task_updated, task_id}, state) do
    if Integrations.background(fn -> sync_and_merge(task_id) end) == :busy,
      do: Feedback.mark_dirty(task_id)

    {:noreply, state}
  end

  defp sync_and_merge(task_id) do
    _synced = Feedback.sync(task_id)
    _observed = PrOutcomes.observe(task_id)
    AutoMerge.check(task_id)
  end
end
