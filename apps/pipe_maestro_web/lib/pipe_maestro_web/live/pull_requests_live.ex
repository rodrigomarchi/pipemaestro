defmodule PipeMaestroWeb.PullRequestsLive do
  @moduledoc """
  The workspace's tasks that have a pull request (pipelines that deliver one,
  `PipeMaestro.Pipelines.Pipeline` `delivery`), with the task's state
  and its issue. Updated live.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.TaskComponents, only: [task_status: 1]
  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]

  alias PipeMaestro.Tasks

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    if connected?(socket), do: Tasks.subscribe({:workspace, workspace.id})
    {:ok, socket |> assign(page_title: "Pull requests") |> load()}
  end

  @impl true
  def handle_info({:task_updated, _task}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    assign(socket,
      tasks: Tasks.list_with_pull_request(socket.assigns.current_scope.workspace),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:pull_requests}
      title="Pull requests"
    >
      <.card variant="outline">
        <.card_header
          title="PRs abertos pelas tarefas"
          description="Pipelines com entrega em PR abrem um rascunho na primeira etapa e o marcam como pronto na última."
        />
        <.card_content>
          <p
            :if={@tasks == []}
            class="text-sm text-gray-500 dark:text-gray-400"
            data-testid="no-pull-requests"
          >
            Nenhum PR ainda. Escolha "Commit, push e PR" na entrega de um pipeline.
          </p>
          <ul class="divide-y divide-gray-100 text-sm dark:divide-gray-800">
            <li
              :for={task <- @tasks}
              class="flex flex-wrap items-center justify-between gap-3 py-3"
              data-testid={"pull-request-#{task.id}"}
            >
              <span class="min-w-0">
                <.link
                  navigate={~p"/w/#{@current_scope.workspace.slug}/tasks/#{task.id}"}
                  class="font-medium text-gray-900 hover:underline dark:text-white"
                >
                  {task.title}
                </.link>
                <a
                  href={task.pr_url}
                  target="_blank"
                  rel="noopener"
                  class="ml-2 font-mono text-xs text-primary-600 hover:underline dark:text-primary-400"
                >
                  {task.pr_url |> String.split("/") |> Enum.take(-2) |> Enum.join("/")}
                </a>
              </span>
              <span class="flex items-center gap-2">
                <.task_status task={task} />
                <span class="text-xs text-gray-500 dark:text-gray-400">{time_ago(
                  task.updated_at,
                  @now
                )}</span>
              </span>
            </li>
          </ul>
        </.card_content>
      </.card>
    </Layouts.app>
    """
  end
end
