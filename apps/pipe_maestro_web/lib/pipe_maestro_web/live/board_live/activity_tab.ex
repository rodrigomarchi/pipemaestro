defmodule PipeMaestroWeb.BoardLive.ActivityTab do
  @moduledoc """
  The board's "Atividade" tab: the workspace's tasks that changed last,
  newest first, each with its status and when it changed. The overview
  shows the first few through `activity_list/1`.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]
  import PipeMaestroWeb.TaskComponents, only: [task_status: 1]

  alias PipeMaestro.Tasks
  alias PipeMaestro.Workspaces.Workspace

  @doc "The `limit` tasks of `workspace` that changed last, newest first."
  @spec load(Workspace.t(), pos_integer()) :: [Tasks.Task.t()]
  def load(%Workspace{} = workspace, limit \\ 20) do
    workspace
    |> Tasks.list_tasks()
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  attr :recent, :list, required: true
  attr :slug, :string, required: true
  attr :now, DateTime, required: true

  @doc "The tab."
  @spec activity(map()) :: Phoenix.LiveView.Rendered.t()
  def activity(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_header title="Atividade recente" description="As tarefas que mudaram por último." />
      <.card_content>
        <.activity_list recent={@recent} slug={@slug} now={@now} testid="board-activity" />
      </.card_content>
    </.card>
    """
  end

  attr :recent, :list, required: true
  attr :slug, :string, required: true
  attr :now, DateTime, required: true
  attr :testid, :string, required: true

  @doc "The tasks, each with its status and when it changed."
  @spec activity_list(map()) :: Phoenix.LiveView.Rendered.t()
  def activity_list(assigns) do
    ~H"""
    <p :if={@recent == []} class="text-sm text-gray-500 dark:text-gray-400">
      Nenhuma tarefa ainda.
    </p>
    <ul class="space-y-3" data-testid={@testid}>
      <li :for={task <- @recent} class="flex items-start justify-between gap-3 text-sm">
        <.link
          navigate={~p"/w/#{@slug}/tasks/#{task.id}"}
          class="min-w-0 truncate text-gray-900 hover:underline dark:text-white"
        >
          {task.title}
        </.link>
        <span class="flex shrink-0 items-center gap-2">
          <.task_status task={task} />
          <span class="text-xs text-gray-500 dark:text-gray-400">
            {time_ago(task.updated_at, @now)}
          </span>
        </span>
      </li>
    </ul>
    """
  end
end
