defmodule PipeMaestroWeb.AuditComponents do
  @moduledoc """
  How the agent worked in a run, for auditing: the session it ran in, where
  its time went, its tokens and cost per model, its tools, its calls to the
  model API, what it was refused, the MCP servers, permission decisions and
  subagents its run reported, what it had at hand and what it wrote on
  stderr. Built from the job and `PipeMaestro.Insights.job/1`.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.JobComponents,
    only: [
      auth_label: 1,
      count_label: 3,
      format_cost: 1,
      format_duration: 1,
      format_percent: 1,
      short_number: 1
    ]

  alias PipeMaestro.Jobs.Job

  @doc "The audit of one job."
  attr :job, Job, required: true
  attr :insights, :map, required: true

  @spec job_audit(map()) :: Phoenix.LiveView.Rendered.t()
  def job_audit(assigns) do
    assigns = assign(assigns, environment: assigns.job.environment || %{})

    ~H"""
    <.card variant="outline" data-testid="job-audit">
      <.card_header title="Auditoria" description="Como o agente trabalhou nesta execução." />
      <.card_content class="space-y-6">
        <section>
          <.heading>Sessão</.heading>
          <dl class="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-3" data-testid="job-audit-session">
            <.fact label="Sessão do CLI" mono>{@job.session_id || "—"}</.fact>
            <.fact label="Versão do CLI" mono>{@job.cli_version || "—"}</.fact>
            <.fact label="Modelo" mono>{@job.model || "—"}</.fact>
            <.fact label="Permissões" mono>{@environment["permission_mode"] || "—"}</.fact>
            <.fact label="Credencial">{auth_label(@environment["auth"])}</.fact>
            <.fact label="Término" mono>{ending(@job)}</.fact>
            <.fact label="Tempo do processo">{format_duration(@job.wall_ms)}</.fact>
            <.fact label="Tempo na API">{format_duration(@job.duration_api_ms)}</.fact>
            <.fact label="Primeiro token">{format_duration(@job.ttft_ms)}</.fact>
          </dl>
        </section>

        <section :if={timing_rows(@insights.timing) != []} data-testid="job-audit-timing">
          <.heading>Para onde foi o tempo</.heading>
          <ul class="space-y-2 text-sm">
            <li
              :for={{key, label, ms, max} <- timing_rows(@insights.timing)}
              class="grid grid-cols-[8rem_1fr_5rem] items-center gap-3"
              data-testid={"job-audit-timing-#{key}"}
            >
              <span class="text-gray-500 dark:text-gray-400">{label}</span>
              <.progress size="sm" value={ms} max={max} color={timing_color(key)} />
              <span class="text-right text-gray-900 dark:text-white">{format_duration(ms)}</span>
            </li>
          </ul>
          <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
            Ferramentas podem rodar ao mesmo tempo: o tempo delas é a soma das chamadas.
          </p>
        </section>

        <section>
          <.heading>Tokens</.heading>
          <dl class="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3 lg:grid-cols-6">
            <.tile label="Entrada nova" value={short_number(@job.input_tokens)} />
            <.tile label="Cache lido" value={short_number(@job.cache_read_tokens)} />
            <.tile label="Cache criado" value={short_number(@job.cache_creation_tokens)} />
            <.tile label="Saída" value={short_number(@job.output_tokens)} />
            <.tile label="Raciocínio" value={short_number(@job.thinking_tokens)} />
            <.tile
              label="Acerto do cache"
              value={format_percent(@insights.cache_hit)}
              testid="job-audit-cache-hit"
            />
          </dl>
          <ul :if={@insights.models != []} class="mt-3 space-y-1 text-sm">
            <li
              :for={model <- @insights.models}
              class="flex flex-wrap justify-between gap-2"
              data-testid={"job-audit-model-#{model.model}"}
            >
              <span class="font-mono text-gray-700 dark:text-gray-300">{model.model}</span>
              <span class="text-gray-500 dark:text-gray-400">
                {short_number(model.fresh_input + model.cache_read + model.cache_creation)} → {short_number(
                  model.output
                )} tokens · {format_cost(model.cost_usd)}
              </span>
            </li>
          </ul>
        </section>

        <section>
          <.heading>Ferramentas</.heading>
          <p
            :if={@insights.tools == []}
            class="text-sm text-gray-500 dark:text-gray-400"
            data-testid="job-audit-no-tools"
          >
            Nenhuma ferramenta usada.
          </p>
          <div :if={@insights.tools != []} class="w-full overflow-x-auto">
            <.table id="job-audit-tools" rows={@insights.tools} row_id={&"job-audit-tool-#{&1.name}"}>
              <:col :let={tool} label="Ferramenta">
                <span class="font-mono" data-testid={"job-audit-tool-#{tool.name}"}>
                  {tool.name}
                </span>
              </:col>
              <:col :let={tool} label="Chamadas">
                <span data-testid={"job-audit-tool-calls-#{tool.name}"}>{tool.calls}</span>
              </:col>
              <:col :let={tool} label="Erros">
                <span class={tool.errors > 0 && "text-danger-700 dark:text-danger-400"}>
                  {tool.errors}
                </span>
              </:col>
              <:col :let={tool} label="Negadas">{tool.denied}</:col>
              <:col :let={tool} label="Tempo">
                <span data-testid={"job-audit-tool-time-#{tool.name}"}>
                  {format_duration(tool.total_ms)}
                </span>
              </:col>
              <:col :let={tool} label="Média">{format_duration(tool.avg_ms)}</:col>
            </.table>
          </div>
        </section>

        <section data-testid="job-audit-api">
          <.heading>API do modelo</.heading>
          <p class="text-sm text-gray-700 dark:text-gray-300">
            {count_label(@insights.api.requests, "requisição", "requisições")}
            <span :if={@insights.api.p50_ms}>
              · mediana {format_duration(@insights.api.p50_ms)} · p95 {format_duration(
                @insights.api.p95_ms
              )} · máx. {format_duration(@insights.api.max_ms)}
            </span>
            <span :if={@insights.api.avg_ttft_ms}>
              · primeiro token em {format_duration(@insights.api.avg_ttft_ms)} em média
            </span>
            · {count_label(@insights.api.retries, "nova tentativa", "novas tentativas")}
            <span :if={@insights.api.refusals > 0} data-testid="job-audit-api-refusals">
              · {count_label(@insights.api.refusals, "recusa", "recusas")}
            </span>
          </p>
          <div :if={@insights.extras.by_query_source != []} class="mt-3 w-full overflow-x-auto">
            <.table
              id="job-audit-api-sources"
              rows={@insights.extras.by_query_source}
              row_id={&"job-audit-api-source-#{&1.source}"}
              density="compact"
            >
              <:col :let={source} label="Origem da chamada">
                <span class="font-mono" data-testid={"job-audit-api-source-#{source.source}"}>
                  {source.source || "—"}
                </span>
              </:col>
              <:col :let={source} label="Requisições">{source.requests}</:col>
              <:col :let={source} label="Custo">{format_cost(source.cost_usd)}</:col>
            </.table>
          </div>
          <ul :if={@insights.api.errors != []} class="mt-2 space-y-1 text-sm">
            <li :for={error <- @insights.api.errors} class="text-danger-700 dark:text-danger-400">
              {error.error}
              <span :if={error.status} class="font-mono">({error.status})</span>
              <span :if={error.attempt}>· tentativa {error.attempt}</span>
            </li>
          </ul>
        </section>

        <section :if={@insights.denials != []} data-testid="job-audit-denials">
          <.heading>Permissões negadas</.heading>
          <ul class="space-y-1 text-sm">
            <li :for={denial <- @insights.denials} class="break-all">
              <span class="font-mono font-medium text-danger-700 dark:text-danger-400">
                {denial["tool_name"]}
              </span>
              <span class="font-mono text-xs text-gray-500 dark:text-gray-400">
                {denial["input"] || denial["text"]}
              </span>
            </li>
          </ul>
        </section>

        <section>
          <.heading>Mais</.heading>
          <dl class="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-3" data-testid="job-audit-more">
            <.fact label="Compactações">{@insights.compactions}</.fact>
            <.fact label="Chamadas de subagentes">{@insights.subagent_calls}</.fact>
            <.fact label="Raciocínios">
              {@insights.thinking.count} · {format_duration(@insights.thinking.total_ms)}
            </.fact>
            <.fact label="Linhas">
              +{@job.telemetry_totals["lines_added"] || 0} −{@job.telemetry_totals[
                "lines_removed"
              ] || 0}
            </.fact>
            <.fact label="Commits e PRs">
              {@job.telemetry_totals["commits"] || 0} · {@job.telemetry_totals["pull_requests"] ||
                0}
            </.fact>
            <.fact label="Limites da conta">{limits(@insights.rate_limit)}</.fact>
            <.fact label="Tempo ativo">
              <span data-testid="job-audit-active-time">
                {format_seconds(@insights.extras.active_seconds)}
              </span>
            </.fact>
          </dl>
        </section>

        <section
          :if={
            @insights.extras.mcp != [] or @insights.extras.decisions != [] or
              @insights.extras.subagents != []
          }
          data-testid="job-audit-extras"
        >
          <.heading>Conexões, permissões e subagentes</.heading>
          <div class="grid gap-4 text-sm sm:grid-cols-3">
            <div :if={@insights.extras.mcp != []} data-testid="job-audit-mcp-connections">
              <p class="text-xs text-gray-500 dark:text-gray-400">
                Servidores MCP
                <span
                  :if={@insights.extras.mcp_failures > 0}
                  class="text-danger-700 dark:text-danger-400"
                >
                  · {count_label(@insights.extras.mcp_failures, "falha", "falhas")}
                </span>
              </p>
              <ul class="mt-1 space-y-1">
                <li :for={connection <- @insights.extras.mcp} class="flex flex-wrap gap-2">
                  <.badge
                    size="sm"
                    variant="soft"
                    color={mcp_color(connection.status)}
                    label={connection.status || "—"}
                  />
                  <span class="font-mono text-xs text-gray-700 dark:text-gray-300">
                    {connection.transport} · {connection.scope}
                  </span>
                  <span class="text-xs text-gray-500 dark:text-gray-400">
                    {format_duration(connection.duration_ms)}
                  </span>
                </li>
              </ul>
            </div>
            <div :if={@insights.extras.decisions != []} data-testid="job-audit-decisions">
              <p class="text-xs text-gray-500 dark:text-gray-400">Decisões de permissão</p>
              <ul class="mt-1 space-y-1">
                <li
                  :for={decision <- @insights.extras.decisions}
                  data-testid={"job-audit-decision-#{decision.source}-#{decision.decision}"}
                >
                  <span class={
                    decision.decision == "reject" && "text-danger-700 dark:text-danger-400"
                  }>
                    {decision_label(decision.decision)}
                  </span>
                  <span class="text-gray-500 dark:text-gray-400">
                    por {decision.source || "—"} · {decision.count}
                  </span>
                </li>
              </ul>
            </div>
            <div :if={@insights.extras.subagents != []} data-testid="job-audit-subagents">
              <p class="text-xs text-gray-500 dark:text-gray-400">Subagentes concluídos</p>
              <ul class="mt-1 space-y-1">
                <li :for={subagent <- @insights.extras.subagents}>
                  <span class="font-mono">{subagent.agent_type || "—"}</span>
                  <span class="text-gray-500 dark:text-gray-400">· {subagent.count}</span>
                </li>
              </ul>
            </div>
          </div>
        </section>

        <details :if={@environment != %{}} data-testid="job-audit-environment">
          <summary class="cursor-pointer text-sm font-medium text-gray-700 dark:text-gray-300">
            Ambiente: {count_label(length(@environment["tools"] || []), "ferramenta", "ferramentas")} · {count_label(
              length(@environment["mcp_servers"] || []),
              "servidor MCP",
              "servidores MCP"
            )}
          </summary>
          <div class="mt-3 space-y-3 text-sm">
            <div :if={@environment["mcp_servers"] not in [nil, []]} class="flex flex-wrap gap-2">
              <.badge
                :for={server <- @environment["mcp_servers"]}
                size="sm"
                variant="soft"
                color={mcp_color(server["status"])}
                label={"#{server["name"]} · #{server["status"]}"}
                data-testid={"job-audit-mcp-#{server["name"]}"}
              />
            </div>
            <.names label="Ferramentas" names={@environment["tools"]} />
            <.names label="Agentes" names={@environment["agents"]} />
            <.names label="Skills" names={@environment["skills"]} />
            <.names
              label="Plugins"
              names={for plugin <- @environment["plugins"] || [], do: plugin["name"]}
            />
          </div>
        </details>

        <details :if={@job.stderr} data-testid="job-audit-stderr">
          <summary class="cursor-pointer text-sm font-medium text-gray-700 dark:text-gray-300">
            Saída de erro do CLI
          </summary>
          <pre class="mt-2 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-gray-50 px-3 py-2 font-mono text-xs text-gray-800 dark:bg-gray-800 dark:text-gray-200">{@job.stderr}</pre>
        </details>
      </.card_content>
    </.card>
    """
  end

  slot :inner_block, required: true

  defp heading(assigns) do
    ~H"""
    <h3 class="mb-2 text-sm font-medium text-gray-900 dark:text-white">
      {render_slot(@inner_block)}
    </h3>
    """
  end

  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-gray-500 dark:text-gray-400">{@label}</dt>
      <dd class={["truncate text-gray-900 dark:text-white", @mono && "font-mono text-xs"]}>
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :testid, :string, default: nil

  defp tile(assigns) do
    ~H"""
    <div class="rounded-lg bg-gray-50 px-3 py-2 dark:bg-gray-800/60">
      <dt class="text-xs text-gray-500 dark:text-gray-400">{@label}</dt>
      <dd class="text-base font-semibold text-gray-900 dark:text-white" data-testid={@testid}>
        {@value}
      </dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :names, :list, default: nil

  defp names(assigns) do
    ~H"""
    <div :if={@names not in [nil, []]}>
      <p class="text-xs text-gray-500 dark:text-gray-400">{@label} ({length(@names)})</p>
      <p class="mt-1 break-words font-mono text-xs text-gray-700 dark:text-gray-300">
        {Enum.join(@names, " · ")}
      </p>
    </div>
    """
  end

  defp ending(%Job{result_subtype: nil, stop_reason: nil}), do: "—"

  defp ending(%Job{} = job),
    do: [job.result_subtype, job.stop_reason] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  defp limits(nil), do: "—"

  defp limits(%{"utilization" => %{} = utilization} = limit) when map_size(utilization) > 0 do
    windows =
      Enum.map_join(Enum.sort(utilization), " · ", fn {window, used} ->
        "#{window} #{round(used * 100)}%"
      end)

    "#{limit["status"]} · #{windows}"
  end

  defp limits(limit), do: limit["status"] || "—"

  @timing [
    {:queue, :queue_ms, "Na fila"},
    {:setup, :setup_ms, "Preparação"},
    {:api, :api_ms, "API do modelo"},
    {:tools, :tools_ms, "Ferramentas"},
    {:gates, :gates_ms, "Gates"},
    {:wall, :wall_ms, "Processo inteiro"}
  ]

  # The known parts of a run's time, each against the longest.
  defp timing_rows(timing) do
    rows =
      for {key, field, label} <- @timing,
          ms = Map.get(timing, field),
          is_integer(ms),
          do: {key, label, ms}

    max = rows |> Enum.map(&elem(&1, 2)) |> Enum.max(fn -> 0 end) |> max(1)
    for {key, label, ms} <- rows, do: {key, label, ms, max}
  end

  defp timing_color(:queue), do: "gray"
  defp timing_color(:setup), do: "info"
  defp timing_color(:api), do: "primary"
  defp timing_color(:tools), do: "secondary"
  defp timing_color(:gates), do: "warning"
  defp timing_color(:wall), do: "success"

  defp format_seconds(seconds) when is_number(seconds), do: format_duration(round(seconds * 1000))
  defp format_seconds(_unknown), do: "—"

  defp decision_label("accept"), do: "Aceitas"
  defp decision_label("reject"), do: "Recusadas"
  defp decision_label(other), do: other || "—"

  defp mcp_color("connected"), do: "success"
  defp mcp_color(status) when status in ~w(failed error), do: "danger"
  defp mcp_color(_pending), do: "warning"

  @doc "How the agent worked across a workspace's runs (`PipeMaestro.Insights.workspace/3`)."
  attr :insights, :map, required: true

  @spec workspace_audit(map()) :: Phoenix.LiveView.Rendered.t()
  def workspace_audit(assigns) do
    ~H"""
    <.card variant="outline" data-testid="usage-agent">
      <.card_header
        title="Agente"
        description="Como o agente trabalhou: tokens e cache, modelos, API, ferramentas e permissões."
      />
      <.card_content class="space-y-6">
        <dl class="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3 lg:grid-cols-6">
          <.tile label="Entrada nova" value={short_number(@insights.tokens.fresh_input)} />
          <.tile label="Cache lido" value={short_number(@insights.tokens.cache_read)} />
          <.tile label="Cache criado" value={short_number(@insights.tokens.cache_creation)} />
          <.tile label="Saída" value={short_number(@insights.tokens.output)} />
          <.tile label="Raciocínio" value={short_number(@insights.tokens.thinking)} />
          <.tile
            label="Acerto do cache"
            value={format_percent(@insights.cache_hit)}
            testid="usage-agent-cache-hit"
          />
        </dl>

        <dl class="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-3">
          <.fact label="API do modelo">
            <span data-testid="usage-agent-api">
              {count_label(@insights.api.requests, "requisição", "requisições")}
              <span :if={@insights.api.avg_ms}>· {format_duration(@insights.api.avg_ms)} em média</span>
            </span>
          </.fact>
          <.fact label="Primeiro token">{format_duration(@insights.api.avg_ttft_ms)}</.fact>
          <.fact label="Erros e novas tentativas">
            {@insights.api.errors} · {@insights.api.retries}
          </.fact>
          <.fact label="Permissões negadas">
            <span data-testid="usage-agent-denials">{@insights.denials}</span>
          </.fact>
          <.fact label="Compactações">{@insights.compactions}</.fact>
          <.fact label="Execuções no período">{@insights.tokens.jobs}</.fact>
          <.fact label="Tempo ativo">
            <span data-testid="usage-agent-active-time">
              {format_seconds(@insights.active_seconds)}
            </span>
          </.fact>
          <.fact label="Recusas da API">{@insights.api.refusals}</.fact>
          <.fact label="Falhas de MCP">
            <span data-testid="usage-agent-mcp-failures">{@insights.mcp_failures}</span>
          </.fact>
        </dl>

        <div :if={@insights.models != []}>
          <.heading>Modelos</.heading>
          <ul class="space-y-1 text-sm">
            <li
              :for={model <- @insights.models}
              class="flex flex-wrap justify-between gap-2"
              data-testid={"usage-agent-model-#{model.model}"}
            >
              <span class="font-mono text-gray-700 dark:text-gray-300">{model.model}</span>
              <span class="text-gray-500 dark:text-gray-400">
                {short_number(model.output)} tokens de saída · {format_cost(model.cost_usd)}
              </span>
            </li>
          </ul>
        </div>

        <div :if={@insights.tools != []}>
          <.heading>Ferramentas</.heading>
          <div class="w-full overflow-x-auto">
            <.table
              id="usage-agent-tools"
              rows={@insights.tools}
              row_id={&"usage-agent-tool-#{&1.name}"}
              density="compact"
            >
              <:col :let={tool} label="Ferramenta">
                <span class="font-mono">{tool.name || "—"}</span>
              </:col>
              <:col :let={tool} label="Chamadas">{tool.calls}</:col>
              <:col :let={tool} label="Erros">
                <span
                  class={tool.errors > 0 && "text-danger-700 dark:text-danger-400"}
                  data-testid={"usage-agent-tool-errors-#{tool.name}"}
                >
                  {tool.errors}
                </span>
              </:col>
              <:col :let={tool} label="Média">{format_duration(tool.avg_ms)}</:col>
            </.table>
          </div>
        </div>
      </.card_content>
    </.card>
    """
  end
end
