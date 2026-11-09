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
  And the quality of what was delivered (`PipeMaestro.Usage.quality/3`): how
  the pull requests were accepted and where the stages were redone,
  corrected or paused. In tabs (`?aba=`), first on the page: the overview
  (totals, cost by day, origin, account limits), the breakdown, the stages,
  how the agent worked and the quality; the filters (pipeline, project,
  period) stay in the top bar.
  """
  use PipeMaestroWeb, :live_view

  import PipeMaestroWeb.JobComponents,
    only: [format_cost: 1, format_duration: 1, short_number: 1]

  import PipeMaestroWeb.AuditComponents, only: [workspace_audit: 1]

  import PipeMaestroWeb.RunnerComponents, only: [rate_limit: 1]
  import PipeMaestroWeb.TabComponents, only: [page_tabs: 1, tab_panel: 1]
  import PipeMaestroWeb.UsageQualityComponents, only: [quality: 1]

  alias PipeMaestro.{Insights, Pipelines, Projects, Proposals, Runners, Usage}
  alias PipeMaestroWeb.{PipelineExplorer, TabComponents}

  @periods ~w(7 30 90)

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace

    {:ok,
     socket
     |> assign(page_title: "Uso e limites", days: 7, pipeline: "", project_id: "")
     |> assign(pipelines: Usage.pipeline_names(workspace))
     |> assign(projects: Projects.list_projects(workspace))
     |> load()}
  end

  # The tabs, by their `aba` parameter, first on the page; the filters stay in
  # the top bar.
  @tabs [
    {"visao", "Visão geral", "hero-chart-bar"},
    {"detalhamento", "Detalhamento", "hero-table-cells"},
    {"etapas", "Por etapa", "hero-queue-list"},
    {"agente", "Como o agente trabalhou", "hero-cpu-chip"},
    {"qualidade", "Qualidade", "hero-check-badge"}
  ]

  @impl true
  def handle_params(params, _uri, socket),
    do:
      {:noreply,
       assign(socket, tabs: @tabs, tab: TabComponents.chosen(@tabs, params["aba"], "visao"))}

  @impl true
  def handle_event("period", %{"period" => params}, socket) do
    days = if params["days"] in @periods, do: String.to_integer(params["days"]), else: 7
    pipeline = if params["pipeline"] in socket.assigns.pipelines, do: params["pipeline"], else: ""

    project_id =
      if Enum.any?(socket.assigns.projects, &(&1.id == params["project_id"])),
        do: params["project_id"],
        else: ""

    {:noreply, socket |> assign(days: days, pipeline: pipeline, project_id: project_id) |> load()}
  end

  defp load(socket) do
    workspace = socket.assigns.current_scope.workspace
    filters = %{"pipeline" => socket.assigns.pipeline, "project_id" => socket.assigns.project_id}
    since = DateTime.add(DateTime.utc_now(), -socket.assigns.days, :day)
    report = Usage.report(workspace, since, filters)
    quality = Usage.quality(workspace, since, filters)
    peak = report.by_day |> Enum.map(&Decimal.to_float(&1.cost_usd)) |> Enum.max(fn -> 0.0 end)
    insights = Insights.workspace(workspace, socket.assigns.days, filters)
    limited = workspace |> Runners.list_runners() |> Enum.filter(& &1.rate_limit)

    socket
    |> assign(report: report, peak: peak, insights: insights, limited: limited, quality: quality)
    |> assign(stage_map: stage_map(workspace, socket.assigns.pipeline, report.by_stage))
  end

  # The pipeline filtered by, as it is now, with what each of its stages
  # spent in the period (matched by key: a stage it no longer has stays in the
  # table only).
  defp stage_map(_workspace, "", _rows), do: nil

  defp stage_map(workspace, name, rows) do
    case Enum.find(Pipelines.list_pipelines(workspace), &(&1.name == name)) do
      nil ->
        nil

      pipeline ->
        metrics =
          for row <- rows,
              row.pipeline == name,
              index = Enum.find_index(pipeline.stages, &(&1.key == row.stage)),
              index != nil,
              into: %{},
              do: {index, stage_metrics(row)}

        %{pipeline: pipeline, metrics: metrics}
    end
  end

  defp stage_metrics(row) do
    [
      {"hero-banknotes", format_cost(row.cost_usd)},
      {"hero-play", plural(row.runs, "execução", "execuções")},
      row.failed > 0 && {"hero-x-circle", plural(row.failed, "falha", "falhas")},
      row.avg_gates_ms && {"hero-shield-check", "gates " <> format_duration(row.avg_gates_ms)}
    ]
    |> Enum.filter(& &1)
  end

  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(count, _one, many), do: "#{count} #{many}"

  defp filter_form(assigns),
    do:
      to_form(
        %{
          "days" => to_string(assigns.days),
          "pipeline" => assigns.pipeline,
          "project_id" => assigns.project_id
        },
        as: "period"
      )

  defp project_name(projects, id), do: Enum.find_value(projects, &(&1.id == id && &1.name))

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
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:usage}
      title="Uso e limites"
    >
      <.filter_bar>
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
            :if={@projects != []}
            field={filter_form(assigns)[:project_id]}
            icon="hero-folder"
            type="select"
            label="Projeto"
            hide_label
            options={[{"Todos os projetos", ""} | Enum.map(@projects, &{&1.name, &1.id})]}
            data-testid="usage-project"
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
      </.filter_bar>

      <div class="space-y-6">
        <.page_tabs
          tabs={@tabs}
          active={@tab}
          path={&~p"/w/#{@current_scope.workspace.slug}/usage?aba=#{&1}"}
          testid="usage"
        />

        <.tab_panel id="visao" active={@tab} testid="usage" class="space-y-6">
          <p class="text-sm text-gray-500 dark:text-gray-400" data-testid="usage-period-label">
            Execuções que rodaram e terminaram nos últimos {@days} dias{if @pipeline != "",
              do: ", só do pipeline #{@pipeline}"}{if @project_id != "",
              do: ", só do projeto #{project_name(@projects, @project_id)}"}.
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
        </.tab_panel>

        <.tab_panel id="detalhamento" active={@tab} testid="usage">
          <div class="grid gap-6 xl:grid-cols-2">
            <.usage_table title="Por pipeline" rows={@report.by_pipeline} testid="usage-by-pipeline" />
            <.usage_table title="Por projeto" rows={@report.by_project} testid="usage-by-project" />
            <.usage_table title="Por runner" rows={@report.by_runner} testid="usage-by-runner" />
            <.usage_table title="Por pessoa" rows={@report.by_person} testid="usage-by-person" />
          </div>
        </.tab_panel>

        <.tab_panel id="etapas" active={@tab} testid="usage" class="space-y-6">
          <.card :if={@stage_map} variant="outline">
            <.card_header
              title="O pipeline, etapa por etapa"
              description="O pipeline como está hoje, com o que cada etapa gastou no período."
            />
            <.live_component
              module={PipelineExplorer}
              id="usage-pipeline"
              pipeline={@stage_map.pipeline}
              opts={[metrics: @stage_map.metrics]}
              testid="usage-pipeline"
            />
          </.card>

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
        </.tab_panel>

        <.tab_panel id="agente" active={@tab} testid="usage">
          <.workspace_audit insights={@insights} />
        </.tab_panel>

        <.tab_panel id="qualidade" active={@tab} testid="usage">
          <.quality quality={@quality} />
        </.tab_panel>
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
