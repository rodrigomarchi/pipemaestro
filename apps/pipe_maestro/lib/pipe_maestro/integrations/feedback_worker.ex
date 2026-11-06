defmodule PipeMaestro.Integrations.FeedbackWorker do
  @moduledoc """
  Reflects each change of a task that came from a linked repository on its
  git host (`PipeMaestro.Integrations.Feedback.sync/1`), in the background:
  it listens to `PipeMaestro.Tasks.subscribe(:linked)`. A sync that fails is
  left for the reconciliation (`PipeMaestro.Integrations.Reconciler`).
  """
  use GenServer

  alias PipeMaestro.Integrations.Feedback
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
    {:ok, _pid} =
      Task.Supervisor.start_child(PipeMaestro.Integrations.TaskSupervisor, fn ->
        Feedback.sync(task_id)
      end)

    {:noreply, state}
  end
end
