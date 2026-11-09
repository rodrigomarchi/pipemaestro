defmodule PipeMaestroWeb.PullRequestsLive do
  @moduledoc """
  The workspace's tasks that have a pull request (pipelines that deliver one,
  `PipeMaestro.Pipelines.Pipeline` `delivery`), with the task's state,
  its issue and what its stages cost. Updated live.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.TaskComponents, only: [task_status: 1, task_tone: 1]
  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]
  import PipeMaestroWeb.JobComponents, only: [format_cost: 1]

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
    tasks = Tasks.list_with_pull_request(socket.assigns.current_scope.workspace)

    assign(socket,
      tasks: tasks,
      costs: tasks |> Enum.map(& &1.id) |> Tasks.costs(),
      now: DateTime.utc_now()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:pull_requests}
      title="Pull requests"
    >
      <.record_list id="pull-requests" testid="pull-requests" empty={@tasks == []}>
        <.record_card
          :for={task <- @tasks}
          id={"pull-request-#{task.id}"}
          testid={"pull-request-#{task.id}"}
          navigate={~p"/w/#{@current_scope.workspace.slug}/tasks/#{task.id}"}
          link_testid={"pull-request-link-#{task.id}"}
          tone={task_tone(task)}
        >
          <:leading><.record_icon icon="hero-rocket-launch" color="primary" /></:leading>
          <:title>{task.title}</:title>
          <:badge><.task_status task={task} /></:badge>
          <:meta interactive>
            <a
              href={task.pr_url}
              target="_blank"
              rel="noopener"
              class="inline-flex items-center gap-1 font-mono text-primary-600 hover:underline dark:text-primary-400"
              data-testid={"pull-request-pr-#{task.id}"}
            >
              {task.pr_url |> String.split("/") |> Enum.take(-2) |> Enum.join("/")}
              <.icon name="hero-arrow-top-right-on-square" class="size-3" />
            </a>
            <span>·</span>
            <span data-testid={"pull-request-project-#{task.id}"}>
              {(task.project || %{})["name"] || task.directory}
            </span>
          </:meta>
          <:aside>
            <.record_metric label="Custo" testid={"pull-request-cost-#{task.id}"}>
              {format_cost(@costs[task.id] || Decimal.new(0))}
            </.record_metric>
            <span>{time_ago(task.updated_at, @now)}</span>
          </:aside>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-pull-requests"
            icon="hero-rocket-launch"
            title="Nenhum PR ainda"
            description={"Pipelines com entrega em PR abrem um rascunho na primeira etapa e o marcam como pronto na última. Escolha \"Commits conferidos, push e PR\" na entrega de um pipeline."}
          />
        </:empty_state>
      </.record_list>
    </Layouts.app>
    """
  end
end
