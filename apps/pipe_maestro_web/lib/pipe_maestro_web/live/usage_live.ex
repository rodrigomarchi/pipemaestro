defmodule PipeMaestroWeb.UsageLive do
  @moduledoc """
  The workspace's usage in the last 7, 30 or 90 days, optionally only a
  pipeline's (`PipeMaestro.Usage`): cost, runs, time and tokens in total and
  by day, by origin (pipeline stages, each kind of proposal, jobs sent on
  their own), by pipeline, runner, person and pipeline stage, where the failed
  runs show which stages retry the most and the averages show how long runs
  wait for their runner and spend in gates; how the agent worked
  (`PipeMaestro.Insights`): tokens and cache, models, API, tools and
  permissions; and how near each runner's account is to its usage limits.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents,
    only: [format_cost: 1, format_duration: 1, short_number: 1]

  import PipeMaestroWeb.AuditComponents, only: [workspace_audit: 1]

  import PipeMaestroWeb.RunnerComponents, only: [rate_limit: 1]

  alias PipeMaestro.{Insights, Proposals, Runners, Usage}

  @periods ~w(7 30 90)

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace

    {:ok,
     socket
     |> assign(page_title: "Uso e limites", days: 7, pipeline: "")
     |> assign(pipelines: Usage.pipeline_names(workspace))
     |> load()}
  end

  @impl true
  def handle_event("period", %{"period" => params}, socket) do
    days = if params["days"] in @periods, do: String.to_integer(params["days"]), else: 7
    pipeline = if params["pipeline"] in socket.assigns.pipelines, do: params["pipeline"], else: ""
    {:noreply, socket |> assign(days: days, pipeline: pipeline) |> load()}
  end

  defp load(socket) do
    workspace = socket.assigns.current_scope.workspace
    filters = %{"pipeline" => socket.assigns.pipeline}
    since = DateTime.add(DateTime.utc_now(), -socket.assigns.days, :day)
    report = Usage.report(workspace, since, filters)
    peak = report.by_day |> Enum.map(&Decimal.to_float(&1.cost_usd)) |> Enum.max(fn -> 0.0 end)
    insights = Insights.workspace(workspace, socket.assigns.days, filters)
    limited = workspace |> Runners.list_runners() |> Enum.filter(& &1.rate_limit)
    assign(socket, report: report, peak: peak, insights: insights, limited: limited)
  end

  defp filter_form(assigns),
    do:
      to_form(%{"days" => to_string(assigns.days), "pipeline" => assigns.pipeline}, as: "period")

  defp origin_rows(rows) do
    for row <- rows,
        do:
          Map.merge(row, %{
            name: origin_label(row.origin),
            key: String.replace(row.origin, ":", "-")
          })
  end

  defp origin_label("stage"), do: "Etapas de pipeline"
  defp origin_label("standalone"), do: "Execuções avulsas"

  defp origin_label("proposal:" <> kind) do
    if kind in Proposals.kinds(),
      do: "Proposta: " <> Proposals.kind_module(kind).label(),
      else: "Proposta: " <> kind
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
          for={filter_form(assigns)}
          id="usage-period"
          phx-change="period"
          class="flex flex-wrap gap-2"
        >
          <.icon_field
            :if={@pipelines != []}
            field={filter_form(assigns)[:pipeline]}
            icon="hero-queue-list"
            type="select"
            label="Pipeline"
            hide_label
            options={[{"Todos os pipelines", ""} | Enum.map(@pipelines, &{&1, &1})]}
            data-testid="usage-pipeline"
          />
          <.icon_field
            field={filter_form(assigns)[:days]}
            icon="hero-calendar-days"
            type="select"
            label="Período"
            hide_label
            options={[
              {"Últimos 7 dias", "7"},
              {"Últimos 30 dias", "30"},
              {"Últimos 90 dias", "90"}
            ]}
            data-testid="usage-period"
          />
        </.form>
      </:actions>

      <div class="space-y-6">
        <p class="text-sm text-gray-500 dark:text-gray-400" data-testid="usage-period-label">
          Execuções que rodaram e terminaram nos últimos {@days} dias{if @pipeline != "",
            do: ", só do pipeline #{@pipeline}"}.
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

        <div class="grid gap-6 xl:grid-cols-2">
          <.usage_table
            title="Por origem"
            rows={origin_rows(@report.by_origin)}
            testid="usage-by-origin"
          />
          <.card :if={@limited != []} variant="outline" data-testid="usage-rate-limits">
            <.card_header
              title="Limites das contas"
              description="O uso de cada runner nas janelas da conta Claude, como a última execução viu."
            />
            <.card_content class="space-y-4">
              <div :for={runner <- @limited}>
                <p class="mb-1 text-sm font-medium text-gray-900 dark:text-white">{runner.name}</p>
                <.rate_limit runner={runner} testid={"usage-rate-limit-#{runner.name}"} />
              </div>
            </.card_content>
          </.card>
        </div>

        <div class="grid gap-6 xl:grid-cols-3">
          <.usage_table title="Por pipeline" rows={@report.by_pipeline} testid="usage-by-pipeline" />
          <.usage_table title="Por runner" rows={@report.by_runner} testid="usage-by-runner" />
          <.usage_table title="Por pessoa" rows={@report.by_person} testid="usage-by-person" />
        </div>

        <.card variant="outline">
          <.card_header
            title="Por etapa"
            description="Execuções que falharam numa etapa viraram retentativas ou decisões. Fila e gates são médias por execução."
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
            <:col :let={row} label="Fila">
              <span data-testid={"usage-stage-queue-#{row.stage}"}>
                {format_duration(row.avg_queue_ms)}
              </span>
            </:col>
            <:col :let={row} label="Gates">{format_duration(row.avg_gates_ms)}</:col>
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
          <li
            :for={row <- @rows}
            class="flex items-center justify-between gap-3 py-2"
            data-testid={row[:key] && "#{@testid}-#{row.key}"}
          >
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
