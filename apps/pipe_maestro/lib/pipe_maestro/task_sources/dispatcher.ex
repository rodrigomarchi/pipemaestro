defmodule PipeMaestro.TaskSources.Dispatcher do
  @moduledoc """
  Reflects each change of a task that has a source on that source
  (`c:PipeMaestro.TaskSources.Source.task_changed/1`): it listens to
  `PipeMaestro.Tasks.subscribe(:sourced)`. A source does its work in the
  background; one no longer registered is skipped.
  """
  use GenServer

  alias PipeMaestro.{Tasks, TaskSources}
  alias PipeMaestro.Tasks.Task

  @doc "Starts the dispatcher."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = Tasks.subscribe(:sourced)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:source_task_updated, %Task{} = task}, state) do
    :ok = TaskSources.task_changed(task)
    {:noreply, state}
  end
end
