defmodule PipeMaestroWeb.RunnerLive do
  @moduledoc """
  One runner: its agent and how it signs in, the directories it offers, its
  task worktrees and disk, the jobs it is running or has waiting, and the
  latest jobs it finished, each leading to its audit. Updated live.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.RunnerComponents

  import PipeMaestroWeb.JobComponents,
    only: [
      job_status: 1,
      prompt_summary: 1,
      prompt_summary: 2,
      format_duration: 1,
      format_cost: 1,
      format_percent: 1,
      short_number: 1
    ]

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.{Jobs, Runners}
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks.StageRun
  alias PipeMaestroWeb.{RunnerActions, RunnerStatus}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace = socket.assigns.current_scope.workspace
    runner = Runners.get_runner!(workspace, id)

    if connected?(socket) do
      RunnerStatus.subscribe(workspace.id)
      Jobs.subscribe({:workspace, workspace.id})
    end

    {:ok, socket |> assign(page_title: runner.name, runner_id: runner.id) |> load()}
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

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket), do: {:noreply, load(socket)}
  def handle_info(:runners_changed, socket), do: {:noreply, load(socket)}

  def handle_info({:job_updated, %Job{runner_id: runner_id}}, socket) do
    if runner_id == socket.assigns.runner_id,
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  defp load(socket) do
    workspace = socket.assigns.current_scope.workspace
    runner = Runners.get_runner!(workspace, socket.assigns.runner_id)

    assign(socket,
      runner: runner,
      online: MapSet.member?(RunnerStatus.online_ids(workspace.id), runner.id),
      jobs: Jobs.active_for_runner(runner),
      recent_jobs: Jobs.recent_for_runner(workspace, runner),
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
      active={:runners}
      title={@runner.name}
    >
      <:actions>
        <.button
          :if={can?(@current_scope, :manage_runners)}
          size="sm"
          variant="ghost"
          color="danger"
          icon="hero-no-symbol"
          phx-click="revoke"
          data-confirm={"Revogar #{@runner.name}? O token deixa de valer e a conexão cai."}
          data-testid="runner-detail-revoke"
        >
          Revogar
        </.button>
        <.button
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/runners"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
        >
          Executores
        </.button>
      </:actions>

      <div class="space-y-6">
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
              <.runner_status online={@online} />
            </div>
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
            <ul :if={@jobs != []} class="divide-y divide-gray-100 dark:divide-gray-800">
              <li
                :for={job <- @jobs}
                class="flex items-center justify-between gap-3 py-2 text-sm"
                data-testid={"runner-job-#{job.id}"}
              >
                <.link
                  navigate={~p"/w/#{@current_scope.workspace.slug}/jobs/#{job.id}"}
                  class="min-w-0 truncate text-gray-900 hover:underline dark:text-white"
                >
                  {prompt_summary(job.prompt)}
                </.link>
                <span class="flex shrink-0 items-center gap-2">
                  <.job_status job={job} />
                  <span class="text-xs text-gray-500 dark:text-gray-400">
                    {time_ago(job.started_at || job.inserted_at, @now)}
                  </span>
                </span>
              </li>
            </ul>
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
            <ul :if={@recent_jobs != []} class="divide-y divide-gray-100 dark:divide-gray-800">
              <li
                :for={job <- @recent_jobs}
                id={"runner-recent-job-#{job.id}"}
                class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 py-2 text-sm"
                data-testid={"runner-recent-job-#{job.id}"}
              >
                <span class="flex min-w-0 items-center gap-2">
                  <.job_status job={job} data-testid={"runner-recent-job-status-#{job.id}"} />
                  <.link
                    navigate={~p"/w/#{@current_scope.workspace.slug}/jobs/#{job.id}"}
                    class="min-w-0 truncate text-gray-900 hover:underline dark:text-white"
                    data-testid={"runner-recent-job-link-#{job.id}"}
                  >
                    {job_label(job)}
                  </.link>
                </span>
                <dl class="flex shrink-0 items-center gap-3 text-xs text-gray-500 dark:text-gray-400">
                  <div class="flex gap-1" title="Duração">
                    <dt class="sr-only">Duração</dt>
                    <.icon name="hero-clock" class="size-4" />
                    <dd data-testid={"runner-recent-job-duration-#{job.id}"}>
                      {format_duration(job.duration_ms || job.wall_ms)}
                    </dd>
                  </div>
                  <div class="flex gap-1" title="Custo">
                    <dt class="sr-only">Custo</dt>
                    <dd class="font-mono" data-testid={"runner-recent-job-cost-#{job.id}"}>
                      {format_cost(job.cost_usd)}
                    </dd>
                  </div>
                  <div class="flex gap-1" title="Tokens">
                    <dt class="sr-only">Tokens</dt>
                    <dd data-testid={"runner-recent-job-tokens-#{job.id}"}>{tokens(job)}</dd>
                    <span aria-hidden="true">tokens</span>
                  </div>
                  <div class="flex gap-1" title="Do cache">
                    <dt class="sr-only">Do cache</dt>
                    <dd data-testid={"runner-recent-job-cache-#{job.id}"}>
                      {format_percent(Job.cache_hit(job))}
                    </dd>
                    <span aria-hidden="true">cache</span>
                  </div>
                </dl>
              </li>
            </ul>
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
    </Layouts.app>
    """
  end

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
