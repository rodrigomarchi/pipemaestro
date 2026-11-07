defmodule PipeMaestroWeb.BoardLive do
  @moduledoc """
  The workspace's board: the week in numbers, the tasks by state (running,
  waiting for a decision, done, failed), filterable by pipeline, runner,
  project and person, the decisions waiting, recent activity and the
  runners. Everything updates live: the alerts follow the runners' presence
  and limits, and an alert on a runner's limit ends by itself when the limit
  resets (`PipeMaestro.Tasks.alerts_change_at/2`).
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.RunnerComponents
  import PipeMaestroWeb.TaskComponents, only: [task_status: 1]
  import PipeMaestroWeb.JobComponents, only: [format_cost: 1]

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.{Jobs, Pipelines, Projects, Runners, RunnerTelemetry, Tasks, Workspaces}
  alias PipeMaestro.Tasks.Task
  alias PipeMaestroWeb.RunnerStatus

  @period_days 7

  # The longest wait before the alerts are recomputed for a reset far ahead.
  @max_alerts_wait :timer.hours(24)

  @columns [
    %{
      id: "running",
      name: "Em execução ou na fila",
      icon: "hero-play",
      statuses: [:queued, :running]
    },
    %{
      id: "awaiting",
      name: "Aguardando decisão",
      icon: "hero-hand-raised",
      statuses: [:awaiting_decision]
    },
    %{id: "done", name: "Concluídas", icon: "hero-check-circle", statuses: [:succeeded]},
    %{
      id: "failed",
      name: "Falharam ou canceladas",
      icon: "hero-x-circle",
      statuses: [:failed, :canceled]
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace

    if connected?(socket) do
      RunnerStatus.subscribe(workspace.id)
      Tasks.subscribe({:workspace, workspace.id})
      Jobs.subscribe({:workspace, workspace.id})
    end

    {:ok,
     socket
     |> assign(
       page_title: "Board",
       columns: @columns,
       filters: %{},
       alerts_timer: nil,
       pipelines: Pipelines.list_pipelines(workspace),
       members: Workspaces.list_members(workspace)
     )
     |> load_tasks()
     |> load_runners()}
  end

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, socket |> load_runners() |> load_alerts()}

  def handle_info(:runners_changed, socket),
    do: {:noreply, socket |> load_runners() |> load_alerts()}

  def handle_info(:alerts_expired, socket), do: {:noreply, load_alerts(socket)}
  def handle_info({:task_updated, _task}, socket), do: {:noreply, load_tasks(socket)}

  # The cost of a job counts as soon as it ends, task or not.
  def handle_info({:job_updated, _job}, socket), do: {:noreply, load_stats(socket)}

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, socket |> assign(filters: filters) |> load_tasks()}
  end

  defp load_tasks(socket) do
    workspace = socket.assigns.current_scope.workspace
    all = Tasks.list_tasks(workspace)

    socket
    |> assign(
      tasks: Tasks.list_tasks(workspace, socket.assigns.filters),
      awaiting: Tasks.list_awaiting(workspace),
      recent: all |> Enum.sort_by(& &1.updated_at, {:desc, DateTime}) |> Enum.take(8),
      projects: Projects.list_projects(workspace)
    )
    |> load_alerts()
    |> load_stats()
  end

  # Recomputes the alerts and keeps one timer for the next instant an alert
  # ends by itself, capped at @max_alerts_wait (it recomputes and waits again).
  defp load_alerts(socket) do
    workspace = socket.assigns.current_scope.workspace
    online = RunnerStatus.online_ids(workspace.id)

    degraded =
      workspace
      |> Runners.list_runners()
      |> Enum.filter(&MapSet.member?(online, &1.id))
      |> RunnerTelemetry.degraded_alerts()

    alerts = Tasks.alerts(workspace, online) ++ degraded

    if timer = socket.assigns.alerts_timer, do: Process.cancel_timer(timer)

    timer =
      case connected?(socket) && Tasks.alerts_change_at(alerts) do
        %DateTime{} = at ->
          wait = DateTime.diff(at, DateTime.utc_now(), :millisecond)
          Process.send_after(self(), :alerts_expired, min(max(wait, 0), @max_alerts_wait))

        _none ->
          nil
      end

    assign(socket, alerts: alerts, alerts_timer: timer)
  end

  defp load_stats(socket) do
    since = DateTime.add(DateTime.utc_now(), -@period_days, :day)
    assign(socket, stats: Tasks.stats(socket.assigns.current_scope.workspace, since))
  end

  defp load_runners(socket) do
    workspace = socket.assigns.current_scope.workspace

    assign(socket,
      runners: Runners.list_runners(workspace),
      online: RunnerStatus.online_ids(workspace.id),
      now: DateTime.utc_now()
    )
  end

  defp column_tasks(tasks, column), do: Enum.filter(tasks, &(&1.status in column.statuses))

  defp stage_label(%Task{stages: stages, current_stage: index}) do
    case Enum.at(stages, index) do
      nil -> "#{length(stages)} etapas"
      stage -> "#{index + 1}/#{length(stages)} · #{stage.name}"
    end
  end

  defp options(values, prompt), do: [{prompt, ""} | values]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:board}
      title="Board"
    >
      <:actions>
        <.button
          size="sm"
          icon="hero-plus"
          to={~p"/w/#{@current_scope.workspace.slug}/tasks"}
          link_type="live_redirect"
          class="hidden sm:inline-flex"
          data-testid="new-task"
        >
          Nova tarefa
        </.button>
      </:actions>

      <div class="space-y-6">
        <.card :if={@alerts != []} variant="outline" class="border-danger-300 dark:border-danger-800">
          <.card_header title="Precisa de atenção" />
          <.card_content>
            <ul class="space-y-2 text-sm">
              <li :for={alert <- @alerts} data-testid={alert_testid(alert)}>
                <.alert_line alert={alert} slug={@current_scope.workspace.slug} />
              </li>
            </ul>
          </.card_content>
        </.card>

        <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.stat_card
            id="running"
            icon="hero-play"
            label="Em execução"
            value={@stats.running}
            hint="agora"
          />
          <.stat_card
            id="awaiting"
            icon="hero-hand-raised"
            label="Aguardando decisão"
            value={@stats.awaiting}
            hint="agora"
          />
          <.stat_card
            id="succeeded"
            icon="hero-check-circle"
            label="Concluídas"
            value={@stats.succeeded}
            hint={"#{@stats.failed} falharam ou canceladas · 7 dias"}
          />
          <.stat_card
            id="cost"
            icon="hero-currency-dollar"
            label="Custo"
            value={format_cost(@stats.cost_usd)}
            hint="execuções dos últimos 7 dias"
          />
        </div>

        <section aria-labelledby="tasks-heading">
          <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
            <h2 id="tasks-heading" class="text-sm font-semibold text-gray-900 dark:text-white">
              Tarefas
            </h2>
            <.form
              for={to_form(@filters, as: "filters")}
              id="board-filters"
              phx-change="filter"
              class="grid w-full grid-cols-2 gap-2 sm:w-auto sm:grid-cols-4"
            >
              <.icon_field
                field={to_form(@filters, as: "filters")[:pipeline]}
                icon="hero-squares-2x2"
                type="select"
                label="Pipeline"
                options={options(Enum.map(@pipelines, & &1.name), "Todos")}
                data-testid="board-filter-pipeline"
              />
              <.icon_field
                field={to_form(@filters, as: "filters")[:runner_id]}
                icon="hero-server-stack"
                type="select"
                label="Runner"
                options={options(Enum.map(@runners, &{&1.name, &1.id}), "Todos")}
                data-testid="board-filter-runner"
              />
              <.icon_field
                field={to_form(@filters, as: "filters")[:project_id]}
                icon="hero-folder-open"
                type="select"
                label="Projeto"
                options={options(Enum.map(@projects, &{&1.name, &1.id}), "Todos")}
                data-testid="board-filter-project"
              />
              <.icon_field
                field={to_form(@filters, as: "filters")[:user_id]}
                icon="hero-user"
                type="select"
                label="Pessoa"
                options={options(Enum.map(@members, &{&1.name, &1.id}), "Todas")}
                data-testid="board-filter-user"
              />
            </.form>
          </div>
          <div class="-mx-4 overflow-x-auto px-4 pb-2 sm:-mx-6 sm:px-6 lg:-mx-8 lg:px-8">
            <div class="grid min-w-[56rem] grid-cols-4 gap-4">
              <.column
                :for={column <- @columns}
                column={column}
                tasks={column_tasks(@tasks, column)}
                slug={@current_scope.workspace.slug}
                now={@now}
              />
            </div>
          </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-3">
          <.card class="xl:col-span-2" variant="outline">
            <.card_header
              title="Decisões pendentes"
              description="Estas tarefas estão pausadas até alguém decidir."
            >
              <:action>
                <.button
                  size="xs"
                  variant="outline"
                  color="gray"
                  icon="hero-hand-raised"
                  to={~p"/w/#{@current_scope.workspace.slug}/decisions"}
                  link_type="live_redirect"
                  data-testid="board-decisions-link"
                >
                  Decidir
                </.button>
              </:action>
            </.card_header>
            <.card_content>
              <div :if={@awaiting != []} class="divide-y divide-gray-200 dark:divide-gray-800">
                <.link
                  :for={task <- @awaiting}
                  navigate={~p"/w/#{@current_scope.workspace.slug}/tasks/#{task.id}"}
                  class="flex items-start gap-3 py-3 first:pt-0 last:pb-0"
                  data-testid={"board-decision-#{task.id}"}
                >
                  <span class="inline-flex size-8 shrink-0 items-center justify-center rounded-full bg-warning-100 text-warning-600 dark:bg-warning-500/15 dark:text-warning-400">
                    <.icon name="hero-hand-raised" class="size-4" />
                  </span>
                  <span class="min-w-0">
                    <span class="block text-sm font-semibold text-gray-900 dark:text-white">
                      {task.title}
                      <span class="font-normal text-gray-500 dark:text-gray-400">
                        · {stage_label(task)}
                      </span>
                    </span>
                    <span class="block text-sm text-gray-600 dark:text-gray-400">
                      {task.decision_reason}
                    </span>
                  </span>
                </.link>
              </div>
              <.empty
                :if={@awaiting == []}
                title="Nenhuma decisão pendente"
                description="Quando uma etapa pedir ajuda, esgotar as tentativas ou estourar o orçamento, a tarefa aparece aqui."
                data-testid="board-no-decisions"
              >
                <:icon><.icon name="hero-check-circle" /></:icon>
              </.empty>
            </.card_content>
          </.card>

          <.card variant="outline">
            <.card_header title="Atividade recente" />
            <.card_content>
              <p
                :if={@recent == []}
                class="text-sm text-gray-500 dark:text-gray-400"
              >
                Nenhuma tarefa ainda.
              </p>
              <ul class="space-y-3" data-testid="board-activity">
                <li :for={task <- @recent} class="flex items-start justify-between gap-3 text-sm">
                  <.link
                    navigate={~p"/w/#{@current_scope.workspace.slug}/tasks/#{task.id}"}
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
            </.card_content>
          </.card>
        </div>

        <.card variant="outline">
          <.card_header
            title="Executores"
            description="Daemons BYO conectados a este workspace."
          >
            <:action>
              <.button
                size="xs"
                variant="outline"
                color="gray"
                icon="hero-server-stack"
                to={~p"/w/#{@current_scope.workspace.slug}/runners"}
                link_type="live_redirect"
                data-testid="board-runners-link"
              >
                Gerenciar
              </.button>
            </:action>
          </.card_header>
          <.table
            :if={@runners != []}
            id="board-runners"
            rows={@runners}
            row_id={&"board-runner-#{&1.id}"}
            density="compact"
          >
            <:col :let={runner} label="Executor">
              <div
                class="flex items-center gap-2 font-medium text-gray-900 dark:text-white"
                data-testid={"board-runner-#{runner.name}"}
              >
                <.icon name="hero-server" class="size-4 text-gray-400" />
                {runner.name}
              </div>
            </:col>
            <:col :let={runner} label="Status">
              <.runner_status
                online={MapSet.member?(@online, runner.id)}
                data-testid={"board-runner-status-#{runner.name}"}
              />
            </:col>
            <:col :let={runner} label="Capacidade">{runner.capacity}</:col>
            <:col :let={runner} label="Versão">
              <span class="font-mono text-xs">{runner.runner_version}</span>
            </:col>
            <:col :let={runner} label="Visto">
              <span class="text-gray-500 dark:text-gray-400">
                {if MapSet.member?(@online, runner.id),
                  do: "agora",
                  else: time_ago(runner.last_seen_at, @now)}
              </span>
            </:col>
          </.table>
          <.card_content :if={@runners == []}>
            <p class="text-sm text-gray-500 dark:text-gray-400" data-testid="board-no-runners">
              Nenhum runner conectado.
              <.link
                navigate={~p"/w/#{@current_scope.workspace.slug}/runners"}
                class="font-medium text-primary-600 hover:text-primary-500 dark:text-primary-400"
              >
                Conectar o primeiro
              </.link>
            </p>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp alert_testid({:runner_offline, task}), do: "board-alert-offline-#{task.id}"
  defp alert_testid({:decision_overdue, task}), do: "board-alert-overdue-#{task.id}"
  defp alert_testid({:near_budget, task, _spent, _cap}), do: "board-alert-budget-#{task.id}"
  defp alert_testid({:runner_near_limit, task, _runner}), do: "board-alert-limit-#{task.id}"

  defp alert_testid({:runner_degraded, runner, _reasons}),
    do: "board-alert-degraded-#{runner.name}"

  attr :alert, :any, required: true
  attr :slug, :string, required: true

  defp alert_line(%{alert: {:runner_offline, task}} = assigns) do
    assigns = assign(assigns, task: task)

    ~H"""
    <.icon name="hero-signal-slash" class="size-4 text-danger-500" />
    <.link navigate={~p"/w/#{@slug}/tasks/#{@task.id}"} class="font-medium hover:underline">
      {@task.title}
    </.link>
    está parada: o runner {if @task.runner, do: @task.runner.name, else: "—"} está offline.
    """
  end

  defp alert_line(%{alert: {:decision_overdue, task}} = assigns) do
    assigns = assign(assigns, task: task)

    ~H"""
    <.icon name="hero-clock" class="size-4 text-danger-500" />
    <.link navigate={~p"/w/#{@slug}/tasks/#{@task.id}"} class="font-medium hover:underline">
      {@task.title}
    </.link>
    espera uma decisão além do prazo.
    """
  end

  defp alert_line(%{alert: {:near_budget, task, spent, cap}} = assigns) do
    assigns = assign(assigns, task: task, spent: spent, cap: cap)

    ~H"""
    <.icon name="hero-currency-dollar" class="size-4 text-warning-500" />
    <.link navigate={~p"/w/#{@slug}/tasks/#{@task.id}"} class="font-medium hover:underline">
      {@task.title}
    </.link>
    já gastou {format_cost(@spent)} de US$ {@cap}.
    """
  end

  defp alert_line(%{alert: {:runner_near_limit, task, runner}} = assigns) do
    assigns = assign(assigns, task: task, runner: runner)

    ~H"""
    <.icon name="hero-exclamation-triangle" class="size-4 text-warning-500" />
    <.link navigate={~p"/w/#{@slug}/tasks/#{@task.id}"} class="font-medium hover:underline">
      {@task.title}
    </.link>
    roda no runner {@runner.name}, cuja conta está perto do limite de uso.
    """
  end

  defp alert_line(%{alert: {:runner_degraded, runner, reasons}} = assigns) do
    assigns = assign(assigns, runner: runner, reasons: reasons)

    ~H"""
    <.icon name="hero-heart" class="size-4 text-danger-500" /> O runner
    <.link
      navigate={~p"/w/#{@slug}/runners/#{@runner.id}?aba=saude"}
      class="font-medium hover:underline"
    >
      {@runner.name}
    </.link>
    está degradado: {Enum.map_join(@reasons, "; ", &reason_label/1)}.
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, required: true

  defp stat_card(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_content>
        <p class="flex items-center gap-1.5 text-sm text-gray-500 dark:text-gray-400">
          <.icon name={@icon} class="size-4 shrink-0" />
          <span class="truncate">{@label}</span>
        </p>
        <p
          class="mt-3 text-2xl font-semibold tracking-tight text-gray-900 dark:text-white"
          data-testid={"board-stat-#{@id}"}
        >
          {@value}
        </p>
        <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">{@hint}</p>
      </.card_content>
    </.card>
    """
  end

  attr :column, :map, required: true
  attr :tasks, :list, required: true
  attr :slug, :string, required: true
  attr :now, DateTime, required: true

  defp column(assigns) do
    ~H"""
    <div
      data-testid={"board-column-#{@column.id}"}
      class="flex min-h-64 flex-col rounded-xl border border-gray-200 bg-gray-100/60 p-3 dark:border-gray-800 dark:bg-gray-900/50"
    >
      <div class="mb-3 flex items-center justify-between px-1">
        <p class="flex items-center gap-1.5 text-sm font-medium text-gray-700 dark:text-gray-200">
          <.icon name={@column.icon} class="size-4 text-gray-400" />
          {@column.name}
        </p>
        <.badge size="xs" color="gray" variant="soft" label={Integer.to_string(length(@tasks))} />
      </div>
      <div class="flex flex-1 flex-col gap-3">
        <.link
          :for={task <- @tasks}
          navigate={~p"/w/#{@slug}/tasks/#{task.id}"}
          data-testid={"board-task-#{task.id}"}
          class={[
            "block rounded-lg border bg-white p-3 shadow-xs transition hover:shadow-md dark:bg-gray-900",
            if(task.status == :awaiting_decision,
              do: "border-warning-300 dark:border-warning-500/40",
              else: "border-gray-200 dark:border-gray-800"
            )
          ]}
        >
          <p class="text-sm font-medium leading-snug text-gray-900 dark:text-white">
            {task.title}
          </p>
          <p class="mt-1 truncate text-xs text-gray-500 dark:text-gray-400">
            {task.pipeline_name} · {stage_label(task)}
          </p>
          <div class="mt-3 flex items-center justify-between gap-2 border-t border-gray-100 pt-2 text-xs text-gray-500 dark:border-gray-800 dark:text-gray-400">
            <span class="flex min-w-0 items-center gap-1">
              <.icon name="hero-folder-micro" class="size-3.5 shrink-0" />
              <span
                class="truncate"
                title={"#{if task.runner, do: task.runner.name, else: "—"}:#{task.directory}"}
                data-testid="board-card-project"
              >
                {(task.project || %{})["name"] || task.directory}
              </span>
            </span>
            <span class="shrink-0">{time_ago(task.updated_at, @now)}</span>
          </div>
        </.link>
        <p
          :if={@tasks == []}
          class="flex flex-1 items-center justify-center rounded-lg border border-dashed border-gray-300 p-4 text-center text-xs text-gray-400 dark:border-gray-700"
        >
          Nenhuma tarefa
        </p>
      </div>
    </div>
    """
  end
end
