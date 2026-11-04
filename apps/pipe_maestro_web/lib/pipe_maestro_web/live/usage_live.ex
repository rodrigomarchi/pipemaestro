defmodule PipeMaestroWeb.UsageLive do
  @moduledoc """
  The workspace's usage in the last 7 or 30 days (`PipeMaestro.Usage`):
  cost, runs, time and tokens in total and by day, and by pipeline, runner,
  person and pipeline stage, where the failed runs show which stages retry the
  most; and how the agent worked (`PipeMaestro.Insights`): tokens and
  cache, models, API, tools and permissions.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents,
    only: [format_cost: 1, format_duration: 1, short_number: 1]

  import PipeMaestroWeb.AuditComponents, only: [workspace_audit: 1]

  alias PipeMaestro.{Insights, Usage}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Uso e limites", days: 7) |> load()}
  end

  @impl true
  def handle_event("period", %{"period" => %{"days" => days}}, socket) when days in ["7", "30"],
    do: {:noreply, socket |> assign(days: String.to_integer(days)) |> load()}

  defp load(socket) do
    since = DateTime.add(DateTime.utc_now(), -socket.assigns.days, :day)
    report = Usage.report(socket.assigns.current_scope.workspace, since)
    peak = report.by_day |> Enum.map(&Decimal.to_float(&1.cost_usd)) |> Enum.max(fn -> 0.0 end)
    insights = Insights.workspace(socket.assigns.current_scope.workspace, socket.assigns.days)
    assign(socket, report: report, peak: peak, insights: insights)
  end

  defp bar_height(_cost, peak) when peak == 0.0, do: 4
  defp bar_height(cost, peak), do: max(4, round(Decimal.to_float(cost) / peak * 100))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:usage}
      title="Uso e limites"
    >
      <:actions>
        <.form
          for={to_form(%{"days" => to_string(@days)}, as: "period")}
          id="usage-period"
          phx-change="period"
        >
          <.icon_field
            field={to_form(%{"days" => to_string(@days)}, as: "period")[:days]}
            icon="hero-calendar-days"
            type="select"
            label="Período"
            hide_label
            options={[{"Últimos 7 dias", "7"}, {"Últimos 30 dias", "30"}]}
            data-testid="usage-period"
          />
        </.form>
      </:actions>

      <div class="space-y-6">
        <p class="text-sm text-gray-500 dark:text-gray-400" data-testid="usage-period-label">
          Execuções que rodaram e terminaram nos últimos {@days} dias.
        </p>

        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.card variant="outline">
            <.card_content>
              <p class="text-sm text-gray-500 dark:text-gray-400">Custo</p>
              <p
                class="mt-2 text-2xl font-semibold text-gray-900 dark:text-white"
                data-testid="usage-total-cost"
              >
                {format_cost(@report.total.cost_usd)}
              </p>
            </.card_content>
          </.card>
          <.card variant="outline">
            <.card_content>
              <p class="text-sm text-gray-500 dark:text-gray-400">Execuções</p>
              <p
                class="mt-2 text-2xl font-semibold text-gray-900 dark:text-white"
                data-testid="usage-total-runs"
              >
                {@report.total.runs}
              </p>
            </.card_content>
          </.card>
          <.card variant="outline">
            <.card_content>
              <p class="text-sm text-gray-500 dark:text-gray-400">Tempo de agente</p>
              <p
                class="mt-2 text-2xl font-semibold text-gray-900 dark:text-white"
                data-testid="usage-total-time"
              >
                {format_duration(@report.total.duration_ms)}
              </p>
            </.card_content>
          </.card>
          <.card variant="outline">
            <.card_content>
              <p class="text-sm text-gray-500 dark:text-gray-400">Tokens</p>
              <p
                class="mt-2 text-2xl font-semibold text-gray-900 dark:text-white"
                data-testid="usage-total-tokens"
              >
                {short_number(@report.total.tokens)}
              </p>
            </.card_content>
          </.card>
        </div>

        <.card variant="outline">
          <.card_header title="Custo por dia" />
          <.card_content>
            <p
              :if={@report.by_day == []}
              class="text-sm text-gray-500 dark:text-gray-400"
              data-testid="usage-empty"
            >
              Nenhuma execução no período.
            </p>
            <div :if={@report.by_day != []} class="flex h-40 gap-2">
              <div
                :for={day <- @report.by_day}
                class="flex h-full min-w-6 max-w-16 flex-1 flex-col items-center gap-1"
                title={"#{Calendar.strftime(day.date, "%d/%m")}: #{format_cost(day.cost_usd)}, #{day.runs} execuções"}
                data-testid={"usage-day-#{day.date}"}
              >
                <div class="flex w-full flex-1 items-end">
                  <div
                    class="w-full rounded-t bg-primary-500 dark:bg-primary-400"
                    style={"height: #{bar_height(day.cost_usd, @peak)}%"}
                  />
                </div>
                <span class="text-[10px] text-gray-500 dark:text-gray-400">
                  {Calendar.strftime(day.date, "%d/%m")}
                </span>
              </div>
            </div>
          </.card_content>
        </.card>

        <div class="grid gap-6 xl:grid-cols-3">
          <.usage_table title="Por pipeline" rows={@report.by_pipeline} testid="usage-by-pipeline" />
          <.usage_table title="Por runner" rows={@report.by_runner} testid="usage-by-runner" />
          <.usage_table title="Por pessoa" rows={@report.by_person} testid="usage-by-person" />
        </div>

        <.card variant="outline">
          <.card_header
            title="Por etapa"
            description="Execuções que falharam numa etapa viraram retentativas ou decisões."
          />
          <.table
            :if={@report.by_stage != []}
            id="usage-by-stage"
            rows={@report.by_stage}
            density="compact"
          >
            <:col :let={row} label="Pipeline">{row.pipeline}</:col>
            <:col :let={row} label="Etapa">{row.name}</:col>
            <:col :let={row} label="Execuções">{row.runs}</:col>
            <:col :let={row} label="Falharam">{row.failed}</:col>
            <:col :let={row} label="Custo">{format_cost(row.cost_usd)}</:col>
            <:col :let={row} label="Tempo">{format_duration(row.duration_ms)}</:col>
            <:col :let={row} label="Tokens">{short_number(row.tokens)}</:col>
          </.table>
        </.card>

        <.workspace_audit insights={@insights} />
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :testid, :string, required: true

  defp usage_table(assigns) do
    ~H"""
    <.card variant="outline" data-testid={@testid}>
      <.card_header title={@title} />
      <.card_content>
        <p :if={@rows == []} class="text-sm text-gray-500 dark:text-gray-400">—</p>
        <ul class="divide-y divide-gray-100 text-sm dark:divide-gray-800">
          <li :for={row <- @rows} class="flex items-center justify-between gap-3 py-2">
            <span class="min-w-0 truncate text-gray-900 dark:text-white">{row.name || "—"}</span>
            <span class="shrink-0 text-gray-500 dark:text-gray-400">
              {format_cost(row.cost_usd)} · {row.runs}
            </span>
          </li>
        </ul>
      </.card_content>
    </.card>
    """
  end
end
