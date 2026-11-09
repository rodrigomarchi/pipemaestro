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
      <.card_content :if={@runners != []}>
        <.record_list id="board-runners">
          <.record_card
            :for={runner <- @runners}
            id={"board-runner-#{runner.id}"}
            testid={"board-runner-row-#{runner.name}"}
            navigate={~p"/w/#{@slug}/runners/#{runner.id}"}
            dense
          >
            <:leading>
              <.record_icon
                icon="hero-server"
                color={if MapSet.member?(@online, runner.id), do: "success", else: "gray"}
              />
            </:leading>
            <:title><span data-testid={"board-runner-#{runner.name}"}>{runner.name}</span></:title>
            <:badge>
              <.runner_status
                online={MapSet.member?(@online, runner.id)}
                data-testid={"board-runner-status-#{runner.name}"}
              />
            </:badge>
            <:aside>
              <.record_metric icon="hero-squares-plus" title="Capacidade">
                {runner.capacity}
              </.record_metric>
              <.record_metric icon="hero-tag" title="Versão">
                <span class="font-mono">{runner.runner_version}</span>
              </.record_metric>
              <.record_metric icon="hero-eye" title="Visto">
                {if MapSet.member?(@online, runner.id),
                  do: "agora",
                  else: time_ago(runner.last_seen_at, @now)}
              </.record_metric>
            </:aside>
          </.record_card>
        </.record_list>
      </.card_content>
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
