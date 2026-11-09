defmodule PipeMaestroWeb.RunnerLive do
  @moduledoc """
  One runner, in tabs (`?aba=`):

    * **Visão geral** — its agent and how it signs in, the directories it
      offers, its task worktrees and disk, how near its account is to its
      usage limits, the jobs it is running or has waiting, and the latest
      jobs it finished, each leading to its audit;
    * **Saúde** — its machine and how its jobs went, over the last day or
      week (`?periodo=`, `PipeMaestroWeb.RunnerLive.HealthTab`);
    * **Eventos e logs** — what happened to it and its own log (`?grupo=`,
      `?nivel=`, `PipeMaestroWeb.RunnerLive.LogTab`);
    * **Conexões** — its uptime and sessions
      (`PipeMaestroWeb.RunnerLive.ConnectionsTab`);
    * **Diagnóstico** — its latest doctor, and a new one on request
      (`PipeMaestroWeb.RunnerLive.DoctorTab`).

  Updated live.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.RunnerComponents

  import PipeMaestroWeb.JobComponents,
    only: [
      job_status: 1,
      job_mark: 1,
      job_tone: 1,
      prompt_summary: 1,
      prompt_summary: 2,
      format_duration: 1,
      format_cost: 1,
      format_percent: 1,
      short_number: 1
    ]

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.{Jobs, Runners, RunnerTelemetry}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.StageRun
  alias PipeMaestroWeb.{RunnerActions, RunnerStatus}
  alias PipeMaestroWeb.RunnerLive.{ConnectionsTab, DoctorTab, HealthTab, LogTab}

  # The tabs, by their `aba` parameter, in order.
  @tabs [
    {"visao", "Visão geral", "hero-server"},
    {"saude", "Saúde", "hero-heart"},
    {"eventos", "Eventos e logs", "hero-queue-list"},
    {"conexoes", "Conexões", "hero-signal"},
    {"diagnostico", "Diagnóstico", "hero-wrench-screwdriver"}
  ]
  @tab_ids Enum.map(@tabs, &elem(&1, 0))

  # How long a requested diagnosis may take before the screen gives up on it.
  @doctor_wait_ms 30_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    runner = Runners.get_runner!(workspace, id)

    if connected?(socket) do
      RunnerStatus.subscribe(workspace.id)
      RunnerStatus.subscribe_telemetry(runner.id)
      Jobs.subscribe({:workspace, workspace.id})
    end

    {:ok,
     assign(socket,
       page_title: runner.name,
       runner_id: runner.id,
       tab: "visao",
       period: "24h",
       group: "tudo",
       level: "info",
       doctor_request: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["aba"] in @tab_ids, do: params["aba"], else: "visao"
    period = if params["periodo"] in HealthTab.periods(), do: params["periodo"], else: "24h"
    group = if params["grupo"] in LogTab.groups(), do: params["grupo"], else: "tudo"
    level = if params["nivel"] in LogTab.levels(), do: params["nivel"], else: "info"

    {:noreply, socket |> assign(tab: tab, period: period, group: group, level: level) |> load()}
  end

  @impl true
  def handle_event("revoke", _params, socket) do
    scope = socket.assigns.current_scope

    if can?(scope, :manage_runners) do
      runner = RunnerActions.revoke(scope, socket.assigns.runner)

      {:noreply,
       socket
       |> put_flash(:info, "Runner #{runner.name} revogado. A conexão foi encerrada.")
       |> push_navigate(to: ~p"/w/#{scope.workspace.slug}/runners")}
    else
      {:noreply, put_flash(socket, :error, "Só admins do workspace gerenciam os runners.")}
    end
  end

  # Any member may ask: the diagnosis only reads the runner's machine.
  def handle_event("run_doctor", _params, socket) do
    request_id = RunnerStatus.request_doctor(socket.assigns.runner_id)
    Process.send_after(self(), {:doctor_timeout, request_id}, @doctor_wait_ms)
    {:noreply, socket |> assign(doctor_request: request_id) |> load()}
  end

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket), do: {:noreply, load(socket)}
  def handle_info(:runners_changed, socket), do: {:noreply, load(socket)}

  # A sample a minute: only the tab that shows it reloads.
  def handle_info({:runner_telemetry, :health}, %{assigns: %{tab: "saude"}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:runner_telemetry, :log}, %{assigns: %{tab: "eventos"}} = socket),
    do: {:noreply, load(socket)}

  # A diagnosis arrived: the one asked for, if it answers the request.
  def handle_info({:runner_telemetry, :doctor}, socket) do
    socket = load(socket)
    answered = socket.assigns.runner.doctor["request_id"] == socket.assigns.doctor_request

    if answered,
      do: {:noreply, socket |> assign(doctor_request: nil) |> load()},
      else: {:noreply, socket}
  end

  def handle_info({:runner_telemetry, _kind}, socket), do: {:noreply, socket}

  def handle_info(
        {:doctor_timeout, request_id},
        %{assigns: %{doctor_request: request_id}} = socket
      ) do
    {:noreply,
     socket
     |> assign(doctor_request: nil)
     |> put_flash(:error, "O runner não respondeu ao pedido de diagnóstico.")
     |> load()}
  end

  def handle_info({:doctor_timeout, _answered}, socket), do: {:noreply, socket}

  def handle_info({:job_updated, %Job{runner_id: runner_id}}, socket) do
    if runner_id == socket.assigns.runner_id,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  defp load(socket) do
    workspace = socket.assigns.current_scope.workspace
    runner = Runners.get_runner!(workspace, socket.assigns.runner_id)

    now = DateTime.utc_now()

    socket
    |> assign(
      runner: runner,
      online: MapSet.member?(RunnerStatus.online_ids(workspace.id), runner.id),
      jobs: Jobs.active_for_runner(runner),
      degraded: RunnerTelemetry.degraded(runner, now),
      now: now
    )
    |> load_tab(socket.assigns.tab, runner, now)
  end

  # Only the open tab's data is read.
  defp load_tab(socket, "visao", runner, _now) do
    workspace = socket.assigns.current_scope.workspace
    assign(socket, recent_jobs: Jobs.recent_for_runner(workspace, runner))
  end

  defp load_tab(socket, "saude", runner, now),
    do: assign(socket, health: HealthTab.load(runner, socket.assigns.period, now))

  defp load_tab(socket, "eventos", runner, now) do
    %{group: group, level: level} = socket.assigns
    assign(socket, log: LogTab.load(runner, group, level, now))
  end

  defp load_tab(socket, "diagnostico", runner, now) do
    %{online: online, doctor_request: pending} = socket.assigns
    assign(socket, doctor: DoctorTab.load(runner, online, pending, now))
  end

  defp load_tab(socket, "conexoes", runner, now),
    do: assign(socket, connections: ConnectionsTab.load(runner, now))

  defp tab_path(scope, runner_id, "visao"),
    do: ~p"/w/#{scope.workspace.slug}/runners/#{runner_id}"

  defp tab_path(scope, runner_id, tab),
    do: ~p"/w/#{scope.workspace.slug}/runners/#{runner_id}?aba=#{tab}"

  defp log_path(scope, runner_id),
    do: &~p"/w/#{scope.workspace.slug}/runners/#{runner_id}?aba=eventos&grupo=#{&1}&nivel=#{&2}"

  defp period_path(scope, runner_id),
    do: &~p"/w/#{scope.workspace.slug}/runners/#{runner_id}?aba=saude&periodo=#{&1}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:runners}
      title={@runner.name}
      back={
        %{
          to: ~p"/w/#{@current_scope.workspace.slug}/runners",
          label: "Executores",
          testid: "back-to-runners"
        }
      }
    >
      <:action
        :if={can?(@current_scope, :manage_runners)}
        label="Revogar"
        icon="hero-no-symbol"
        on_click="revoke"
        confirm={"Revogar #{@runner.name}? O token deixa de valer e a conexão cai."}
        danger
        testid="runner-detail-revoke"
      />

      <div class="space-y-6">
        <.tabs variant="underline" class="overflow-x-auto" data-testid="runner-tabs">
          <.tab
            :for={{id, label, icon} <- tabs()}
            link_type="live_patch"
            to={tab_path(@current_scope, @runner.id, id)}
            is_active={@tab == id}
            variant="underline"
            data-testid={"runner-tab-#{id}"}
          >
            <.icon name={icon} class="mr-1.5 size-4" /> {label}
          </.tab>
        </.tabs>

        <HealthTab.health
          :if={@tab == "saude"}
          data={@health}
          path={period_path(@current_scope, @runner.id)}
        />
        <LogTab.log :if={@tab == "eventos"} data={@log} path={log_path(@current_scope, @runner.id)} />
        <ConnectionsTab.connections :if={@tab == "conexoes"} data={@connections} />
        <DoctorTab.doctor :if={@tab == "diagnostico"} data={@doctor} />

        <div :if={@tab == "visao"} class="space-y-6">
          <.card variant="outline">
            <.card_content>
              <div class="flex flex-wrap items-center justify-between gap-2">
                <p class="font-mono text-sm text-gray-600 dark:text-gray-300">
                  {@runner.hostname} · {@runner.os}/{@runner.arch} · runner
                  <.runner_version
                    runner={@runner}
                    version_testid="runner-detail-version"
                    outdated_testid="runner-detail-outdated"
                  />
                </p>
                <span class="flex items-center gap-2">
                  <.health_badge reasons={@degraded} data-testid="runner-detail-degraded" />
                  <.runner_status online={@online} />
                </span>
              </div>
              <ul
                :if={@degraded != []}
                class="mt-3 list-inside list-disc text-sm text-danger-700 dark:text-danger-400"
                data-testid="runner-detail-degraded-reasons"
              >
                <li :for={reason <- @degraded}>{reason_label(reason)}</li>
              </ul>
              <dl class="mt-4 grid gap-4 text-sm sm:grid-cols-3">
                <div>
                  <dt class="text-gray-500 dark:text-gray-400">Agente</dt>
                  <dd class="text-gray-900 dark:text-white" data-testid="runner-detail-agent">
                    <span :if={!@runner.agent}>—</span>
                    <span :if={@runner.agent} class="font-mono">
                      claude {@runner.agent["cli_version"] || "não encontrado"}
                    </span>
                    <span :if={@runner.agent}>
                      · {if @runner.agent["auth"] == "api_key",
                        do: "chave de API do runner",
                        else: "login pessoal"}
                    </span>
                  </dd>
                </div>
                <div>
                  <dt class="text-gray-500 dark:text-gray-400">Capacidade</dt>
                  <dd class="text-gray-900 dark:text-white">
                    {length(Enum.filter(@jobs, &(&1.status == :running)))}/{@runner.capacity} em execução
                  </dd>
                </div>
                <div>
                  <dt class="text-gray-500 dark:text-gray-400">Worktrees</dt>
                  <dd class="text-gray-900 dark:text-white" data-testid="runner-detail-worktrees">
                    {worktrees(@runner.worktree_usage)}
                  </dd>
                </div>
              </dl>
              <div :if={@runner.rate_limit} class="mt-4 max-w-md">
                <p class="mb-2 text-sm text-gray-500 dark:text-gray-400">Limites da conta</p>
                <.rate_limit runner={@runner} testid="runner-rate-limit" />
              </div>
            </.card_content>
          </.card>

          <.card variant="outline">
            <.card_header title="Jobs em execução e na fila" />
            <.card_content>
              <p
                :if={@jobs == []}
                class="text-sm text-gray-500 dark:text-gray-400"
                data-testid="runner-no-jobs"
              >
                Nada rodando nem esperando.
              </p>
              <.record_list :if={@jobs != []} id="runner-jobs">
                <.record_card
                  :for={job <- @jobs}
                  id={"runner-job-#{job.id}"}
                  testid={"runner-job-#{job.id}"}
                  navigate={~p"/w/#{@current_scope.workspace.slug}/jobs/#{job.id}"}
                  tone={job_tone(job)}
                  dense
                >
                  <:leading><.job_mark job={job} small /></:leading>
                  <:title>{prompt_summary(job.prompt)}</:title>
                  <:badge><.job_status job={job} /></:badge>
                  <:aside>
                    <.record_metric icon="hero-clock">
                      {time_ago(job.started_at || job.inserted_at, @now)}
                    </.record_metric>
                  </:aside>
                </.record_card>
              </.record_list>
            </.card_content>
          </.card>

          <.card variant="outline" data-testid="runner-recent-jobs">
            <.card_header
              title="Últimas execuções"
              description="As mais recentes que este runner terminou; cada uma leva à auditoria."
            />
            <.card_content>
              <p
                :if={@recent_jobs == []}
                class="text-sm text-gray-500 dark:text-gray-400"
                data-testid="runner-no-recent-jobs"
              >
                Este runner ainda não terminou nenhuma execução.
              </p>
              <.record_list :if={@recent_jobs != []} id="runner-recent-jobs-list">
                <.record_card
                  :for={job <- @recent_jobs}
                  id={"runner-recent-job-#{job.id}"}
                  testid={"runner-recent-job-#{job.id}"}
                  navigate={~p"/w/#{@current_scope.workspace.slug}/jobs/#{job.id}"}
                  link_testid={"runner-recent-job-link-#{job.id}"}
                  tone={job_tone(job)}
                  dense
                >
                  <:leading><.job_mark job={job} small /></:leading>
                  <:title>{job_label(job)}</:title>
                  <:badge>
                    <.job_status job={job} data-testid={"runner-recent-job-status-#{job.id}"} />
                  </:badge>
                  <:aside>
                    <.record_metric
                      icon="hero-clock"
                      title="Duração"
                      testid={"runner-recent-job-duration-#{job.id}"}
                    >
                      {format_duration(job.duration_ms || job.wall_ms)}
                    </.record_metric>
                    <.record_metric
                      icon="hero-banknotes"
                      title="Custo"
                      testid={"runner-recent-job-cost-#{job.id}"}
                    >
                      {format_cost(job.cost_usd)}
                    </.record_metric>
                    <.record_metric
                      icon="hero-cpu-chip"
                      label="tokens"
                      testid={"runner-recent-job-tokens-#{job.id}"}
                    >
                      {tokens(job)}
                    </.record_metric>
                    <.record_metric
                      icon="hero-bolt"
                      label="cache"
                      testid={"runner-recent-job-cache-#{job.id}"}
                    >
                      {format_percent(Job.cache_hit(job))}
                    </.record_metric>
                  </:aside>
                </.record_card>
              </.record_list>
            </.card_content>
          </.card>

          <.card variant="outline">
            <.card_header
              title="Diretórios"
              description="Os subdiretórios da raiz com que o runner foi iniciado."
            />
            <.card_content>
              <p :if={@runner.directories == []} class="text-sm text-gray-500 dark:text-gray-400">
                Nenhum: o runner foi iniciado sem raiz (make runner.start ROOT=~/src).
              </p>
              <ul
                :if={@runner.directories != []}
                class="grid gap-x-6 gap-y-1 font-mono text-sm sm:grid-cols-3"
                data-testid="runner-detail-directories"
              >
                <li :for={dir <- @runner.directories} class="flex items-center gap-2">
                  <.icon name="hero-folder" class="size-4 text-gray-400" />
                  <span class="text-gray-900 dark:text-white">{dir["name"]}</span>
                  <span :if={!dir["git"]} class="text-xs text-gray-500">sem git</span>
                </li>
              </ul>
            </.card_content>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp tabs, do: @tabs

  # A pipeline stage's job reads as its task and stage; any other, as its prompt.
  defp job_label(%Job{stage_run: %StageRun{task: task, name: name, attempt: attempt}}) do
    retry = if attempt > 1, do: " (tentativa #{attempt})", else: ""
    "#{task.title} · #{name}#{retry}"
  end

  defp job_label(%Job{prompt: prompt}), do: prompt_summary(prompt, 70)

  # No token column reported sums to zero: shown as a dash.
  defp tokens(job) do
    case Job.tokens(job) do
      0 -> "—"
      count -> short_number(count)
    end
  end

  defp worktrees(nil), do: "—"

  defp worktrees(%{"count" => count, "bytes" => bytes} = usage) do
    free = if usage["free_bytes"], do: " (#{format_bytes(usage["free_bytes"])} livres)", else: ""
    "#{count} · #{format_bytes(bytes)}#{free}"
  end
end
