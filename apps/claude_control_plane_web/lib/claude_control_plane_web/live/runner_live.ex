defmodule ClaudeControlPlaneWeb.RunnerLive do
  @moduledoc """
  One runner: its agent and how it signs in, the directories it offers, its
  task worktrees and disk, and the jobs it is running or has waiting. Updated
  live.
  """
  use ClaudeControlPlaneWeb, :live_view

  import ClaudeControlPlaneWeb.RunnerComponents
  import ClaudeControlPlaneWeb.JobComponents, only: [job_status: 1, prompt_summary: 1]

  alias ClaudeControlPlane.{Jobs, Runners}
  alias ClaudeControlPlaneWeb.{RunnerActions, RunnerStatus}
  alias Phoenix.Socket.Broadcast

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
  def handle_info({:job_updated, _job}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    workspace = socket.assigns.current_scope.workspace
    runner = Runners.get_runner!(workspace, socket.assigns.runner_id)

    assign(socket,
      runner: runner,
      online: MapSet.member?(RunnerStatus.online_ids(workspace.id), runner.id),
      jobs: Jobs.active_for_runner(runner),
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
                {@runner.hostname} · {@runner.os}/{@runner.arch} · runner {@runner.runner_version}
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

  defp worktrees(nil), do: "—"

  defp worktrees(%{"count" => count, "bytes" => bytes} = usage) do
    free = if usage["free_bytes"], do: " (#{format_bytes(usage["free_bytes"])} livres)", else: ""
    "#{count} · #{format_bytes(bytes)}#{free}"
  end
end
