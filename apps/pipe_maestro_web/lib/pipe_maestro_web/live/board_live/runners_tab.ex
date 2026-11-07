defmodule PipeMaestroWeb.BoardLive.RunnersTab do
  @moduledoc """
  The board's "Executores" tab: the workspace's runners, online or not,
  with their capacity, version and when they were last seen.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.RunnerComponents, only: [runner_status: 1, time_ago: 2]

  attr :runners, :list, required: true
  attr :online, :any, required: true, doc: "a `MapSet` of the online runners' ids"
  attr :slug, :string, required: true
  attr :now, DateTime, required: true

  @doc "The tab."
  @spec runners(map()) :: Phoenix.LiveView.Rendered.t()
  def runners(assigns) do
    ~H"""
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
            to={~p"/w/#{@slug}/runners"}
            link_type="live_redirect"
            data-testid="board-runners-link"
          >
            Gerenciar
          </.button>
        </:action>
      </.card_header>
      <.table
        :if={@runners != []}
        class="mt-4"
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
            navigate={~p"/w/#{@slug}/runners"}
            class="font-medium text-primary-600 hover:text-primary-500 dark:text-primary-400"
          >
            Conectar o primeiro
          </.link>
        </p>
      </.card_content>
    </.card>
    """
  end
end
