defmodule PipeMaestroWeb.BoardLive do
  @moduledoc """
  The workspace's board, in tabs (`?aba=`):

    * **Visão geral** — what needs attention, the week in numbers, the next
      decisions and the latest activity
      (`PipeMaestroWeb.BoardLive.OverviewTab`);
    * **Tarefas** — the tasks by state, filterable by pipeline, runner,
      project and person, the filters in the URL
      (`PipeMaestroWeb.BoardLive.TasksTab`);
    * **Decisões** — every task waiting for a decision
      (`PipeMaestroWeb.BoardLive.DecisionsTab`);
    * **Atividade** — the tasks that changed last
      (`PipeMaestroWeb.BoardLive.ActivityTab`);
    * **Executores** — the runners, online or not
      (`PipeMaestroWeb.BoardLive.RunnersTab`).

  Everything updates live, and so do the counters on the tabs (the alerts,
  the decisions waiting and the runners online), whatever tab is open. An
  alert on a runner's limit ends by itself when the limit resets
  (`PipeMaestro.Tasks.alerts_change_at/1`).
  """
  use PipeMaestroWeb, :live_view

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.{Jobs, Runners, RunnerTelemetry, Tasks}
  alias PipeMaestroWeb.BoardLive.{ActivityTab, DecisionsTab, OverviewTab, RunnersTab, TasksTab}
  alias PipeMaestroWeb.RunnerStatus

  # The tabs, by their `aba` parameter, in order.
  @tabs [
    {"visao", "Visão geral", "hero-home"},
    {"tarefas", "Tarefas", "hero-view-columns"},
    {"decisoes", "Decisões", "hero-hand-raised"},
    {"atividade", "Atividade", "hero-clock"},
    {"executores", "Executores", "hero-server-stack"}
  ]
  @tab_ids Enum.map(@tabs, &elem(&1, 0))

  # The longest wait before the alerts are recomputed for a reset far ahead.
  @max_alerts_wait :timer.hours(24)

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace

    if connected?(socket) do
      RunnerStatus.subscribe(workspace.id)
      Tasks.subscribe({:workspace, workspace.id})
      Jobs.subscribe({:workspace, workspace.id})
    end

    {:ok, assign(socket, page_title: "Board", tab: "visao", filters: %{}, alerts_timer: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["aba"] in @tab_ids, do: params["aba"], else: "visao"

    {:noreply,
     socket
     |> assign(tab: tab, filters: url_filters(params))
     |> load_runners()
     |> load_alerts()
     |> load_tab()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    query = filters |> url_filters() |> Map.put("aba", "tarefas")
    slug = socket.assigns.current_scope.workspace.slug
    {:noreply, push_patch(socket, to: ~p"/w/#{slug}?#{query}")}
  end

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, socket |> load_runners() |> load_alerts()}

  def handle_info(:runners_changed, socket),
    do: {:noreply, socket |> load_runners() |> load_alerts()}

  def handle_info(:alerts_expired, socket), do: {:noreply, load_alerts(socket)}

  def handle_info({:task_updated, _task}, socket),
    do: {:noreply, socket |> load_alerts() |> load_tab()}

  # The cost of a job counts as soon as it ends, task or not: only the
  # overview shows it.
  def handle_info({:job_updated, _job}, %{assigns: %{tab: "visao"}} = socket),
    do: {:noreply, load_tab(socket)}

  def handle_info({:job_updated, _job}, socket), do: {:noreply, socket}

  # The non-empty filters the tasks tab takes.
  defp url_filters(params) do
    params
    |> Map.take(TasksTab.filter_keys())
    |> Map.reject(fn {_key, value} -> value in ["", nil] end)
  end

  # Only the open tab's data is read; the runners and the alerts are always,
  # for the counters on the tabs.
  defp load_tab(%{assigns: %{tab: "visao"}} = socket),
    do: assign(socket, overview: OverviewTab.load(workspace(socket), socket.assigns.now))

  defp load_tab(%{assigns: %{tab: "tarefas", filters: filters}} = socket),
    do: assign(socket, board: TasksTab.load(workspace(socket), filters))

  defp load_tab(%{assigns: %{tab: "decisoes"}} = socket),
    do: assign(socket, awaiting: DecisionsTab.load(workspace(socket)))

  defp load_tab(%{assigns: %{tab: "atividade"}} = socket),
    do: assign(socket, recent: ActivityTab.load(workspace(socket)))

  defp load_tab(%{assigns: %{tab: "executores"}} = socket), do: socket

  defp workspace(socket), do: socket.assigns.current_scope.workspace

  # Recomputes the alerts and keeps one timer for the next instant an alert
  # ends by itself, capped at @max_alerts_wait (it recomputes and waits again).
  defp load_alerts(socket) do
    %{runners: runners, online: online} = socket.assigns
    workspace = workspace(socket)

    degraded =
      runners
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

  defp load_runners(socket) do
    workspace = workspace(socket)

    assign(socket,
      runners: Runners.list_runners(workspace),
      online: RunnerStatus.online_ids(workspace.id),
      now: DateTime.utc_now()
    )
  end

  defp tab_path(slug, "visao"), do: ~p"/w/#{slug}"
  defp tab_path(slug, tab), do: ~p"/w/#{slug}?aba=#{tab}"

  # The counter on a tab, or nil when it shows none.
  defp tab_count("visao", alerts, _pending, _runners, _online), do: positive(length(alerts))
  defp tab_count("decisoes", _alerts, pending, _runners, _online), do: positive(pending)

  defp tab_count("executores", _alerts, _pending, runners, online),
    do: "#{Enum.count(runners, &MapSet.member?(online, &1.id))}/#{length(runners)}"

  defp tab_count(_tab, _alerts, _pending, _runners, _online), do: nil

  defp positive(count) when is_integer(count) and count > 0, do: Integer.to_string(count)
  defp positive(_count), do: nil

  defp tab_color("executores"), do: "gray"
  defp tab_color("decisoes"), do: "warning"
  defp tab_color(_tab), do: "danger"

  defp tabs, do: @tabs

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:board}
      title="Board"
    >
      <:action
        label="Nova tarefa"
        icon="hero-plus"
        navigate={~p"/w/#{@current_scope.workspace.slug}/tasks"}
        primary
        testid="new-task"
      />

      <div class="space-y-6">
        <.tabs variant="underline" class="overflow-x-auto" data-testid="board-tabs">
          <.tab
            :for={{id, label, icon} <- tabs()}
            link_type="live_patch"
            to={tab_path(@current_scope.workspace.slug, id)}
            is_active={@tab == id}
            variant="underline"
            class="whitespace-nowrap"
            data-testid={"board-tab-#{id}"}
          >
            <.icon name={icon} class="mr-1.5 size-4" /> {label}
            <.badge
              :if={tab_count(id, @alerts, @pending_decisions, @runners, @online)}
              size="xs"
              variant="soft"
              color={tab_color(id)}
              class="ml-1.5"
              label={tab_count(id, @alerts, @pending_decisions, @runners, @online)}
              data-testid={"board-tab-count-#{id}"}
            />
          </.tab>
        </.tabs>

        <OverviewTab.overview
          :if={@tab == "visao"}
          data={@overview}
          alerts={@alerts}
          slug={@current_scope.workspace.slug}
          now={@now}
        />
        <TasksTab.tasks
          :if={@tab == "tarefas"}
          data={@board}
          filters={@filters}
          runners={@runners}
          slug={@current_scope.workspace.slug}
          now={@now}
        />
        <DecisionsTab.decisions
          :if={@tab == "decisoes"}
          awaiting={@awaiting}
          slug={@current_scope.workspace.slug}
        />
        <ActivityTab.activity
          :if={@tab == "atividade"}
          recent={@recent}
          slug={@current_scope.workspace.slug}
          now={@now}
        />
        <RunnersTab.runners
          :if={@tab == "executores"}
          runners={@runners}
          online={@online}
          slug={@current_scope.workspace.slug}
          now={@now}
        />
      </div>
    </Layouts.app>
    """
  end
end
