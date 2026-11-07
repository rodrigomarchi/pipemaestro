defmodule PipeMaestroWeb.BoardLive.OverviewTab do
  @moduledoc """
  The board's "Visão geral" tab: what needs attention (tasks stopped or
  overdue, near their budget or their runner's limits, and degraded
  runners), the week in numbers, the next decisions and the latest
  activity, each summary leading to its full tab.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.RunnerComponents, only: [reason_label: 1]
  import PipeMaestroWeb.JobComponents, only: [format_cost: 1]

  alias PipeMaestro.Tasks
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroWeb.BoardLive.{ActivityTab, DecisionsTab}

  @period_days 7
  @decisions 3
  @activity 5

  @doc "What the tab shows of `workspace` as of `now`."
  @spec load(Workspace.t(), DateTime.t()) :: map()
  def load(%Workspace{} = workspace, now) do
    since = DateTime.add(now, -@period_days, :day)

    %{
      stats: Tasks.stats(workspace, since),
      awaiting: workspace |> DecisionsTab.load() |> Enum.take(@decisions),
      recent: ActivityTab.load(workspace, @activity)
    }
  end

  attr :data, :map, required: true
  attr :alerts, :list, required: true
  attr :slug, :string, required: true
  attr :now, DateTime, required: true

  @doc "The tab."
  @spec overview(map()) :: Phoenix.LiveView.Rendered.t()
  def overview(assigns) do
    ~H"""
    <div class="space-y-6">
      <.card :if={@alerts != []} variant="outline" class="border-danger-300 dark:border-danger-800">
        <.card_header title="Precisa de atenção" />
        <.card_content>
          <ul class="space-y-2 text-sm">
            <li :for={alert <- @alerts} data-testid={alert_testid(alert)}>
              <.alert_line alert={alert} slug={@slug} />
            </li>
          </ul>
        </.card_content>
      </.card>

      <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <.stat_card
          id="running"
          icon="hero-play"
          label="Em execução"
          value={@data.stats.running}
          hint="agora"
        />
        <.stat_card
          id="awaiting"
          icon="hero-hand-raised"
          label="Aguardando decisão"
          value={@data.stats.awaiting}
          hint="agora"
        />
        <.stat_card
          id="succeeded"
          icon="hero-check-circle"
          label="Concluídas"
          value={@data.stats.succeeded}
          hint={"#{@data.stats.failed} falharam ou canceladas · 7 dias"}
        />
        <.stat_card
          id="cost"
          icon="hero-currency-dollar"
          label="Custo"
          value={format_cost(@data.stats.cost_usd)}
          hint="execuções dos últimos 7 dias"
        />
      </div>

      <div class="grid gap-6 xl:grid-cols-3">
        <.card class="xl:col-span-2" variant="outline" data-testid="board-overview-decisions">
          <.card_header
            title="Próximas decisões"
            description="Estas tarefas estão pausadas até alguém decidir."
          >
            <:action>
              <.see_all to={~p"/w/#{@slug}?aba=decisoes"} testid="board-overview-decisions-all" />
            </:action>
          </.card_header>
          <.card_content>
            <DecisionsTab.decision_list
              awaiting={@data.awaiting}
              slug={@slug}
              testid="board-overview-decision"
            />
            <p
              :if={@data.awaiting == []}
              class="text-sm text-gray-500 dark:text-gray-400"
              data-testid="board-overview-no-decisions"
            >
              Nenhuma decisão pendente.
            </p>
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_header title="Atividade recente">
            <:action>
              <.see_all to={~p"/w/#{@slug}?aba=atividade"} testid="board-overview-activity-all" />
            </:action>
          </.card_header>
          <.card_content>
            <ActivityTab.activity_list
              recent={@data.recent}
              slug={@slug}
              now={@now}
              testid="board-overview-activity"
            />
          </.card_content>
        </.card>
      </div>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :testid, :string, required: true

  defp see_all(assigns) do
    ~H"""
    <.button
      size="xs"
      variant="ghost"
      color="gray"
      to={@to}
      link_type="live_patch"
      data-testid={@testid}
    >
      Ver tudo
    </.button>
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
end
