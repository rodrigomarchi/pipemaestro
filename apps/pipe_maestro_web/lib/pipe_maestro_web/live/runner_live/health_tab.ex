defmodule PipeMaestroWeb.RunnerLive.HealthTab do
  @moduledoc """
  The runner page's "Saúde" tab: its machine's CPU, memory, load and free
  disk over the last day or week, each with its latest value and a trend,
  and how its jobs went over the last week (failures, setup, queue and
  gates), from `PipeMaestro.RunnerTelemetry`.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.RunnerComponents, only: [format_bytes: 1, format_uptime: 1, time_ago: 2]
  import PipeMaestroWeb.JobComponents, only: [format_duration: 1]

  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.RunnerTelemetry
  alias PipeMaestro.RunnerTelemetry.HealthSample

  # The periods, by their `periodo` parameter: how far back and the bucket.
  @periods %{"24h" => {86_400, 300}, "7d" => {7 * 86_400, 3_600}}

  @doc "The periods the tab offers, by their `periodo` parameter."
  @spec periods() :: [String.t()]
  def periods, do: ["24h", "7d"]

  @doc "What the tab shows of `runner` over `period` as of `now`."
  @spec load(Runner.t(), String.t(), DateTime.t()) :: map()
  def load(%Runner{} = runner, period, now) do
    {seconds, bucket} = Map.fetch!(@periods, period)
    series = RunnerTelemetry.health_series(runner, DateTime.add(now, -seconds, :second), bucket)

    %{
      # A runner that never connected has announced nothing yet.
      outdated: runner.last_connected_at != nil and not Runners.capable?(runner, "health"),
      period: period,
      latest: RunnerTelemetry.latest_health(runner),
      series: series,
      stats: RunnerTelemetry.run_stats(runner, DateTime.add(now, -7, :day)),
      now: now
    }
  end

  attr :data, :map, required: true
  attr :path, :any, required: true, doc: "the tab's path for a period"

  @doc "The tab."
  @spec health(map()) :: Phoenix.LiveView.Rendered.t()
  def health(assigns) do
    ~H"""
    <div class="space-y-6" data-testid="runner-health">
      <.alert
        :if={@data.outdated}
        color="warning"
        with_icon
        data-testid="runner-health-unsupported"
      >
        Esta versão do runner não envia a saúde da máquina. Atualize o runner para ver a CPU, a
        memória e o disco aqui.
      </.alert>

      <.card variant="outline">
        <.card_header
          title="Máquina"
          description={latest_description(@data.latest, @data.now)}
        >
          <:action>
            <.tabs variant="segmented" data-testid="runner-health-periods">
              <.tab
                :for={period <- periods()}
                link_type="live_patch"
                variant="segmented"
                to={@path.(period)}
                is_active={@data.period == period}
                data-testid={"runner-health-period-#{period}"}
              >
                {if period == "24h", do: "24 h", else: "7 dias"}
              </.tab>
            </.tabs>
          </:action>
        </.card_header>
        <.card_content>
          <p
            :if={!@data.latest}
            class="text-sm text-gray-500 dark:text-gray-400"
            data-testid="runner-health-empty"
          >
            Nenhuma amostra ainda: o runner envia uma por minuto enquanto está online.
          </p>
          <div :if={@data.latest} class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <.metric
              id="cpu"
              label="CPU"
              value={percent(@data.latest.cpu_pct)}
              points={points(@data.series, :cpu_pct)}
              color="text-primary-500"
            />
            <.metric
              id="memory"
              label="Memória"
              value={memory(@data.latest)}
              points={points(@data.series, :mem_pct)}
              color="text-secondary-500"
            />
            <.metric
              id="load"
              label="Load (1 min)"
              value={decimal(@data.latest.load1)}
              points={points(@data.series, :load1)}
              color="text-warning-500"
            />
            <.metric
              id="disk"
              label="Disco livre"
              value={disk(@data.latest)}
              points={points(@data.series, :disk_free_bytes)}
              color="text-success-500"
            />
          </div>
        </.card_content>
      </.card>

      <.card variant="outline" data-testid="runner-run-stats">
        <.card_header
          title="Execução nos últimos 7 dias"
          description="Os jobs que o runner terminou: quantos falharam e quanto esperaram."
        />
        <.card_content>
          <dl class="grid gap-4 text-sm sm:grid-cols-3 lg:grid-cols-6">
            <.stat id="runs" label="Jobs" value={to_string(@data.stats.runs)} />
            <.stat id="failures" label="Falhas" value={failures(@data.stats)} />
            <.stat id="setup" label="Setup p50 / p95" value={setup(@data.stats)} />
            <.stat id="queue" label="Fila p50" value={format_duration(@data.stats.queue_p50_ms)} />
            <.stat id="gates" label="Gates p50" value={format_duration(@data.stats.gates_p50_ms)} />
            <.stat
              id="outbox"
              label="Outbox pendente"
              value={to_string((@data.latest && @data.latest.outbox_pending) || "—")}
            />
          </dl>
        </.card_content>
      </.card>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :points, :list, required: true
  attr :color, :string, required: true

  defp metric(assigns) do
    ~H"""
    <div
      class="rounded-lg border border-gray-200 p-4 dark:border-gray-700"
      data-testid={"runner-health-#{@id}"}
    >
      <p class="text-sm text-gray-500 dark:text-gray-400">{@label}</p>
      <p
        class="mt-1 text-lg font-semibold text-gray-900 dark:text-white"
        data-testid={"runner-health-#{@id}-value"}
      >
        {@value}
      </p>
      <.sparkline
        :if={length(@points) >= 2}
        data={@points}
        class={["mt-2 h-10 w-full", @color]}
        data-testid={"runner-health-#{@id}-trend"}
      />
      <p :if={length(@points) < 2} class="mt-2 h-10 text-xs text-gray-400">
        A tendência aparece com mais amostras.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div>
      <dt class="text-gray-500 dark:text-gray-400">{@label}</dt>
      <dd
        class="text-lg font-semibold text-gray-900 dark:text-white"
        data-testid={"runner-stat-#{@id}"}
      >
        {@value}
      </dd>
    </div>
    """
  end

  defp latest_description(nil, _now), do: "CPU, memória, load e disco da máquina do runner."

  defp latest_description(%HealthSample{at: at}, now),
    do: "CPU, memória, load e disco da máquina do runner. Última amostra #{time_ago(at, now)}."

  defp points(series, key), do: series |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1)

  defp percent(nil), do: "—"
  defp percent(value), do: "#{round(value)}%"

  defp decimal(nil), do: "—"

  defp decimal(value),
    do: value |> :erlang.float_to_binary(decimals: 2) |> String.replace(".", ",")

  defp memory(%HealthSample{mem_used_bytes: used, mem_total_bytes: total} = sample)
       when is_integer(used) and is_integer(total) do
    "#{percent(HealthSample.mem_share(sample) * 100)} · #{format_bytes(used)} de #{format_bytes(total)}"
  end

  defp memory(_sample), do: "—"

  defp disk(%HealthSample{disk_free_bytes: free} = sample) when is_integer(free) do
    case HealthSample.disk_free_share(sample) do
      nil -> format_bytes(free)
      share -> "#{format_bytes(free)} (#{percent(share * 100)})"
    end
  end

  defp disk(_sample), do: "—"

  defp failures(%{runs: 0}), do: "—"
  defp failures(%{failed: failed, failure_rate: rate}), do: "#{failed} (#{format_uptime(rate)})"

  defp setup(%{setup_p50_ms: nil}), do: "—"

  defp setup(%{setup_p50_ms: p50, setup_p95_ms: p95}),
    do: "#{format_duration(p50)} / #{format_duration(p95)}"
end
