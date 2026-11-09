defmodule PipeMaestroWeb.UsageQualityComponents do
  @moduledoc """
  The quality tab of Usage (`PipeMaestroWeb.UsageLive`), from
  `PipeMaestro.Usage.quality/3`: how the delivered pull requests were
  accepted (cards, by pipeline, by week), the rework by stage and the stages
  that stop the most for a decision.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.JobComponents, only: [format_duration: 1]

  @doc "The quality tab's content."
  attr :quality, :map, required: true, doc: "`PipeMaestro.Usage.quality/3`"

  @spec quality(map()) :: Phoenix.LiveView.Rendered.t()
  def quality(assigns) do
    ~H"""
    <div class="space-y-6">
      <.card :if={@quality.total.delivered == 0} variant="outline" data-testid="usage-quality-empty">
        <.card_content class="flex items-start gap-3">
          <.record_icon icon="hero-check-badge" color="gray" />
          <div>
            <p class="font-medium text-gray-900 dark:text-white">Nenhum PR entregue no período</p>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Contam as tarefas de repositórios vinculados que terminaram com um pull request
              pronto. Retrabalho e pausas por etapa, abaixo, valem para todas as tarefas.
            </p>
          </div>
        </.card_content>
      </.card>

      <div :if={@quality.total.delivered > 0} class="space-y-6">
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.rate_card
            label="Aceitos sem alteração"
            icon="hero-check-badge"
            value={percent(@quality.total.clean_pct)}
            detail={"#{@quality.total.accepted_clean} de #{@quality.total.delivered}"}
            testid="usage-quality-clean"
          />
          <.rate_card
            label="Aceitos com alteração"
            icon="hero-pencil-square"
            value={percent(@quality.total.changed_pct)}
            detail={"#{@quality.total.accepted_changed} de #{@quality.total.delivered}"}
            testid="usage-quality-changed"
          />
          <.rate_card
            label="Fechados sem integrar"
            icon="hero-x-circle"
            value={percent(@quality.total.closed_pct)}
            detail={"#{@quality.total.closed} de #{@quality.total.delivered}"}
            testid="usage-quality-closed"
          />
          <.rate_card
            label="Em aberto"
            icon="hero-clock"
            value={to_string(@quality.total.open)}
            detail="ainda sem merge"
            testid="usage-quality-open"
          />
        </div>

        <.card variant="outline">
          <.card_content class="flex flex-wrap gap-x-8 gap-y-3 text-sm">
            <.record_metric icon="hero-arrow-up-tray" label="PRs entregues">
              <span data-testid="usage-quality-delivered">{@quality.total.delivered}</span>
            </.record_metric>
            <.record_metric icon="hero-clock" label="Mediana até o merge">
              <span data-testid="usage-quality-merge-time">
                {format_duration(@quality.total.median_merge_ms)}
              </span>
            </.record_metric>
            <.record_metric icon="hero-chat-bubble-left-right" label="Rodadas de review por PR">
              <span data-testid="usage-quality-review-rounds">
                {decimal(@quality.total.review_rounds_per_pr)}
              </span>
            </.record_metric>
          </.card_content>
          <p
            :if={@quality.total.untracked > 0}
            class="px-6 pb-4 text-xs text-gray-500 dark:text-gray-400"
            data-testid="usage-quality-untracked"
          >
            {@quality.total.untracked} PR(s) sem leitura de commits: a integração está no modo
            runner, e só os reviews contam como alteração.
          </p>
        </.card>

        <.card variant="outline" data-testid="usage-quality-by-pipeline">
          <.card_header
            title="Por pipeline"
            description="Os PRs que ficaram prontos no período, pelo pipeline que os entregou."
          />
          <.table id="usage-quality-pipelines" rows={@quality.by_pipeline} density="compact">
            <:col :let={row} label="Pipeline">
              <span data-testid={"usage-quality-pipeline-#{row.name}"}>
                <span class="font-medium">{row.name || "—"}</span>
                · {percent(row.clean_pct)} sem alteração
                · {percent(row.changed_pct)} com alteração
              </span>
            </:col>
            <:col :let={row} label="PRs">{row.delivered}</:col>
            <:col :let={row} label="Fechados">{percent(row.closed_pct)}</:col>
            <:col :let={row} label="Em aberto">{row.open}</:col>
            <:col :let={row} label="Até o merge">{format_duration(row.median_merge_ms)}</:col>
            <:col :let={row} label="Reviews/PR">{decimal(row.review_rounds_per_pr)}</:col>
          </.table>
        </.card>

        <.card variant="outline" data-testid="usage-quality-weeks">
          <.card_header title="Aceitos sem alteração por semana" />
          <.card_content>
            <div class="flex h-32 gap-2">
              <div
                :for={week <- @quality.by_week}
                class="flex h-full min-w-10 max-w-20 flex-1 flex-col items-center gap-1"
                title={"Semana de #{Calendar.strftime(week.week, "%d/%m")}: #{week.accepted_clean} de #{week.delivered}"}
                data-testid={"usage-quality-week-#{week.week}"}
              >
                <span class="text-xs text-gray-600 dark:text-gray-300">
                  {percent(week.clean_pct)}
                </span>
                <div class="flex w-full flex-1 items-end">
                  <div
                    class="w-full rounded-t bg-success-500 dark:bg-success-400"
                    style={"height: #{max(round(week.clean_pct), 3)}%"}
                  />
                </div>
                <span class="text-[10px] text-gray-500 dark:text-gray-400">
                  {Calendar.strftime(week.week, "%d/%m")}
                </span>
              </div>
            </div>
          </.card_content>
        </.card>
      </div>

      <.card variant="outline" data-testid="usage-quality-stages">
        <.card_header
          title="Retrabalho por etapa"
          description="No período: tentativas além da primeira, etapas refeitas (decisões e execuções perdidas), decisões, pausas e correções por quem pediu."
        />
        <p
          :if={@quality.by_stage == []}
          class="px-6 pb-6 text-sm text-gray-500 dark:text-gray-400"
        >
          Nenhuma etapa rodou no período.
        </p>
        <.table
          :if={@quality.by_stage != []}
          id="usage-quality-stage-table"
          rows={@quality.by_stage}
          density="compact"
        >
          <:col :let={row} label="Pipeline">{row.pipeline}</:col>
          <:col :let={row} label="Etapa">
            <span data-testid={stage_id(row)}>{row.name}</span>
          </:col>
          <:col :let={row} label="Retentativas">
            <span data-testid={stage_id(row, "retries")}>{row.retries}</span>
          </:col>
          <:col :let={row} label="Refeita">
            <span data-testid={stage_id(row, "redone")}>{row.redone}</span>
          </:col>
          <:col :let={row} label="Decisões">
            <span data-testid={stage_id(row, "decisions")}>{row.decisions}</span>
          </:col>
          <:col :let={row} label="Correção por review">
            <span data-testid={stage_id(row, "review-fixes")}>{row.review_fixes}</span>
          </:col>
          <:col :let={row} label="Correção do merge">
            <span data-testid={stage_id(row, "merge-fixes")}>{row.merge_fixes}</span>
          </:col>
          <:col :let={row} label="Correção pedida">
            <span data-testid={stage_id(row, "person-fixes")}>{row.person_fixes}</span>
          </:col>
        </.table>
      </.card>

      <.card variant="outline" data-testid="usage-quality-pauses">
        <.card_header
          title="Etapas que mais pausam"
          description="Pausas para decisão no período, contando as que esperam agora."
        />
        <.card_content>
          <.record_list empty={@quality.top_pauses == []} testid="usage-quality-pause-list">
            <.record_card
              :for={row <- @quality.top_pauses}
              testid={"usage-quality-pause-#{row.pipeline}-#{row.stage}"}
              tone={:awaiting}
              dense
            >
              <:leading><.record_icon icon="hero-pause-circle" color="warning" small /></:leading>
              <:title>{row.name}</:title>
              <:meta>
                <.record_fact icon="hero-queue-list" title="Pipeline">{row.pipeline}</.record_fact>
              </:meta>
              <:aside>
                <.record_metric icon="hero-pause" title="Pausas">{row.pauses}</.record_metric>
              </:aside>
            </.record_card>
            <:empty_state>
              <.record_empty
                title="Nenhuma pausa no período"
                icon="hero-pause-circle"
                testid="usage-quality-pauses-empty"
              />
            </:empty_state>
          </.record_list>
        </.card_content>
      </.card>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :value, :string, required: true
  attr :detail, :string, required: true
  attr :testid, :string, required: true

  defp rate_card(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_content>
        <p class="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400">
          <.icon name={@icon} class="size-4" /> {@label}
        </p>
        <p
          class="mt-2 text-2xl font-semibold text-gray-900 dark:text-white"
          data-testid={@testid}
        >
          {@value}
        </p>
        <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">{@detail}</p>
      </.card_content>
    </.card>
    """
  end

  defp stage_id(row), do: "usage-quality-stage-#{row.pipeline}-#{row.stage}"
  defp stage_id(row, column), do: stage_id(row) <> "-" <> column

  defp percent(value), do: "#{round(value)}%"

  defp decimal(value), do: :erlang.float_to_binary(value / 1, decimals: 1)
end
