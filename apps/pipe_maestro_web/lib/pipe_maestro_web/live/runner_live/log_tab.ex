defmodule PipeMaestroWeb.RunnerLive.LogTab do
  @moduledoc """
  The runner page's "Eventos e logs" tab: what happened to the runner over
  the last week (updates, dropped connections, setups and deliveries that
  failed...), filtered by group (`?grupo=`), and the latest lines of its own
  log from a level up (`?nivel=`), newest first, live (`PipeMaestro.RunnerTelemetry`).
  """
  use PipeMaestroWeb, :html

  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.RunnerTelemetry
  alias PipeMaestro.RunnerTelemetry.LogLine

  @groups [
    {"tudo", "Tudo"},
    {"errors", "Erros"},
    {"setup", "Setup"},
    {"git", "Git"},
    {"update", "Atualização"},
    {"connection", "Conexão"},
    {"worktree", "Worktrees"},
    {"doctor", "Diagnóstico"}
  ]

  @levels [{"debug", "Tudo"}, {"info", "Info+"}, {"warning", "Avisos+"}, {"error", "Erros"}]

  @doc "The groups of events the tab filters by (`grupo`)."
  @spec groups() :: [String.t()]
  def groups, do: Enum.map(@groups, &elem(&1, 0))

  @doc "The levels the log is shown from (`nivel`)."
  @spec levels() :: [String.t()]
  def levels, do: Enum.map(@levels, &elem(&1, 0))

  @doc "What the tab shows of `runner`, for the events of `group` and the log from `level`."
  @spec load(Runner.t(), String.t(), String.t(), DateTime.t()) :: map()
  def load(%Runner{} = runner, group, level, now) do
    %{
      group: group,
      level: level,
      outdated: runner.last_connected_at != nil and not Runners.capable?(runner, "logs"),
      keep_logs: RunnerTelemetry.keep_logs?(runner),
      events:
        RunnerTelemetry.events(
          runner,
          DateTime.add(now, -7, :day),
          if(group == "tudo", do: nil, else: group)
        ),
      # The newest first: what just happened is on top.
      lines: runner |> RunnerTelemetry.log_lines(level) |> Enum.reverse()
    }
  end

  attr :data, :map, required: true
  attr :path, :any, required: true, doc: "the tab's path for a group and a level"

  @doc "The tab."
  @spec log(map()) :: Phoenix.LiveView.Rendered.t()
  def log(assigns) do
    ~H"""
    <div class="space-y-6" data-testid="runner-log">
      <.alert :if={@data.outdated} color="warning" with_icon data-testid="runner-log-unsupported">
        Esta versão do runner não envia o próprio log. Atualize o runner para ver o log aqui; os
        eventos de setup e de entrega aparecem mesmo assim.
      </.alert>

      <.card variant="outline">
        <.card_header
          title="Eventos"
          description="O que aconteceu com o runner nos últimos 7 dias, fora o trabalho dos jobs."
        />
        <.card_content>
          <.tabs variant="segmented" class="mb-4 overflow-x-auto" data-testid="runner-event-groups">
            <.tab
              :for={{group, label} <- groups_with_labels()}
              link_type="live_patch"
              variant="segmented"
              to={@path.(group, @data.level)}
              is_active={@data.group == group}
              data-testid={"runner-event-group-#{group}"}
            >
              {label}
            </.tab>
          </.tabs>
          <p
            :if={@data.events == []}
            class="text-sm text-gray-500 dark:text-gray-400"
            data-testid="runner-no-events"
          >
            Nenhum evento neste filtro.
          </p>
          <ul :if={@data.events != []} class="divide-y divide-gray-100 dark:divide-gray-800">
            <li
              :for={event <- @data.events}
              class="flex flex-wrap items-start justify-between gap-x-4 gap-y-1 py-2 text-sm"
              data-testid={"runner-event-#{event.kind}"}
            >
              <span class="flex min-w-0 items-start gap-2">
                <.icon
                  name={level_icon(event.level)}
                  class={["mt-0.5 size-4 shrink-0", level_color(event.level)]}
                />
                <span class="min-w-0 break-words text-gray-900 dark:text-white">
                  {event.message}
                </span>
              </span>
              <span class="flex shrink-0 items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                <.badge size="xs" variant="soft" color="gray" label={kind_label(event.kind)} />
                {Calendar.strftime(event.at, "%d/%m %H:%M:%S")}
              </span>
            </li>
          </ul>
        </.card_content>
      </.card>

      <.card variant="outline">
        <.card_header
          title="Log do runner"
          description="As últimas linhas que o runner escreveu, as mais recentes primeiro, com os segredos já redigidos na máquina."
        >
          <:action>
            <.tabs variant="segmented" data-testid="runner-log-levels">
              <.tab
                :for={{level, label} <- levels_with_labels()}
                link_type="live_patch"
                variant="segmented"
                to={@path.(@data.group, level)}
                is_active={@data.level == level}
                data-testid={"runner-log-level-#{level}"}
              >
                {label}
              </.tab>
            </.tabs>
          </:action>
        </.card_header>
        <.card_content>
          <p
            :if={!@data.keep_logs}
            class="text-sm text-gray-500 dark:text-gray-400"
            data-testid="runner-log-not-kept"
          >
            Este workspace não guarda o log dos runners, só os eventos. A retenção se ajusta no
            backoffice.
          </p>
          <p
            :if={@data.keep_logs and @data.lines == []}
            class="text-sm text-gray-500 dark:text-gray-400"
            data-testid="runner-no-log-lines"
          >
            Nenhuma linha neste nível.
          </p>
          <div
            :if={@data.keep_logs and @data.lines != []}
            id="runner-log-lines"
            class="max-h-[32rem] overflow-auto rounded-lg bg-gray-950 p-3 font-mono text-xs leading-5 text-gray-200 dark:border dark:border-gray-800"
            data-testid="runner-log-lines"
          >
            <div
              :for={line <- @data.lines}
              class="flex gap-2 py-0.5"
              data-testid="runner-log-line"
            >
              <span class="shrink-0 text-gray-500">{Calendar.strftime(line.at, "%d/%m %H:%M:%S")}</span>
              <span class={["shrink-0", line_level_color(line)]}>[{line.level}]</span>
              <span class="min-w-0 whitespace-pre-wrap break-words">{String.trim(line.message)}</span>
            </div>
          </div>
        </.card_content>
      </.card>
    </div>
    """
  end

  defp groups_with_labels, do: @groups
  defp levels_with_labels, do: @levels

  @doc "An event's kind, in Portuguese."
  @spec kind_label(String.t()) :: String.t()
  def kind_label("update_applied"), do: "atualizado"
  def kind_label("update_failed"), do: "atualização falhou"
  def kind_label("connection_lost"), do: "conexão perdida"
  def kind_label("outbox_dropped"), do: "fila cheia"
  def kind_label("log_dropped"), do: "log descartado"
  def kind_label("setup_failed"), do: "setup falhou"
  def kind_label("delivery_failed"), do: "entrega falhou"
  def kind_label("credential_refused"), do: "credencial recusada"
  def kind_label("scratch_remove_failed"), do: "scratch não saiu"
  def kind_label("worktree_remove_failed"), do: "worktree não saiu"
  def kind_label("doctor_changed"), do: "diagnóstico mudou"
  def kind_label(kind), do: kind

  defp level_icon("error"), do: "hero-x-circle"
  defp level_icon("warning"), do: "hero-exclamation-triangle"
  defp level_icon(_level), do: "hero-information-circle"

  defp level_color("error"), do: "text-danger-500"
  defp level_color("warning"), do: "text-warning-500"
  defp level_color(_level), do: "text-gray-400"

  defp line_level_color(%LogLine{level: "error"}), do: "text-danger-400"
  defp line_level_color(%LogLine{level: "warning"}), do: "text-warning-400"
  defp line_level_color(_line), do: "text-gray-400"
end
