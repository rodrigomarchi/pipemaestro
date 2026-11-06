defmodule PipeMaestroWeb.RunnerLive.ConnectionsTab do
  @moduledoc """
  The runner page's "Conexões" tab: the share of the last day and week the
  runner spent connected, a band of when it was online over the week, and
  its sessions, each with how it ended (`PipeMaestro.RunnerTelemetry`).
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.RunnerComponents, only: [format_uptime: 1]
  import PipeMaestroWeb.JobComponents, only: [format_duration: 1]

  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.RunnerTelemetry
  alias PipeMaestro.RunnerTelemetry.Session

  @week 7 * 24 * 3_600

  @doc "What the tab shows of `runner` as of `now`."
  @spec load(Runner.t(), DateTime.t()) :: map()
  def load(%Runner{} = runner, now) do
    week_ago = DateTime.add(now, -@week, :second)
    day_ago = DateTime.add(now, -1, :day)
    sessions = RunnerTelemetry.sessions(runner, week_ago)

    %{
      uptime_day: RunnerTelemetry.uptime(runner, day_ago, now),
      uptime_week: RunnerTelemetry.uptime(runner, week_ago, now),
      drops_day: RunnerTelemetry.drops(runner, day_ago, now),
      band: band(sessions, week_ago, now),
      sessions: sessions,
      now: now
    }
  end

  attr :data, :map, required: true

  @doc "The tab."
  @spec connections(map()) :: Phoenix.LiveView.Rendered.t()
  def connections(assigns) do
    ~H"""
    <div class="space-y-6" data-testid="runner-connections">
      <.card variant="outline">
        <.card_content>
          <dl class="grid gap-4 text-sm sm:grid-cols-3">
            <div>
              <dt class="text-gray-500 dark:text-gray-400">Uptime 24 h</dt>
              <dd
                class="text-lg font-semibold text-gray-900 dark:text-white"
                data-testid="runner-uptime-day"
              >
                {format_uptime(@data.uptime_day)}
              </dd>
            </div>
            <div>
              <dt class="text-gray-500 dark:text-gray-400">Uptime 7 dias</dt>
              <dd
                class="text-lg font-semibold text-gray-900 dark:text-white"
                data-testid="runner-uptime-week"
              >
                {format_uptime(@data.uptime_week)}
              </dd>
            </div>
            <div>
              <dt class="text-gray-500 dark:text-gray-400">Quedas em 24 h</dt>
              <dd
                class="text-lg font-semibold text-gray-900 dark:text-white"
                data-testid="runner-drops-day"
              >
                {@data.drops_day}
              </dd>
            </div>
          </dl>

          <p class="mt-6 mb-2 text-sm text-gray-500 dark:text-gray-400">Online nos últimos 7 dias</p>
          <div
            class="relative h-4 w-full overflow-hidden rounded bg-gray-200 dark:bg-gray-700"
            data-testid="runner-uptime-band"
          >
            <span
              :for={{left, width} <- @data.band}
              class="absolute inset-y-0 bg-success-500"
              style={"left: #{left}%; width: #{width}%"}
            />
          </div>
          <div class="mt-1 flex justify-between text-xs text-gray-500 dark:text-gray-400">
            <span>há 7 dias</span>
            <span>agora</span>
          </div>
        </.card_content>
      </.card>

      <.card variant="outline">
        <.card_header
          title="Sessões"
          description="Cada conexão do runner, da entrada à queda, e os joins recusados."
        />
        <.card_content>
          <p
            :if={@data.sessions == []}
            class="text-sm text-gray-500 dark:text-gray-400"
            data-testid="runner-no-sessions"
          >
            Nenhuma conexão nos últimos 7 dias.
          </p>
          <ul :if={@data.sessions != []} class="divide-y divide-gray-100 dark:divide-gray-800">
            <li
              :for={session <- @data.sessions}
              class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 py-2 text-sm"
              data-testid="runner-session"
            >
              <span class="flex items-center gap-2">
                <.icon
                  name={session_icon(session)}
                  class={["size-4", session_color(session)]}
                />
                <span class="text-gray-900 dark:text-white">
                  {Calendar.strftime(session.started_at, "%d/%m %H:%M:%S")}
                </span>
                <span :if={session.runner_version} class="font-mono text-xs text-gray-500">
                  {session.runner_version}
                </span>
              </span>
              <span class="flex items-center gap-3 text-xs text-gray-500 dark:text-gray-400">
                <span :if={!Session.refused?(session)}>
                  {format_duration(duration_ms(session, @data.now))}
                </span>
                <.badge
                  size="xs"
                  variant="soft"
                  color={reason_color(session)}
                  label={reason_label(session)}
                  data-testid="runner-session-reason"
                />
              </span>
            </li>
          </ul>
        </.card_content>
      </.card>
    </div>
    """
  end

  @doc "How a session ended, in Portuguese."
  @spec reason_label(Session.t()) :: String.t()
  def reason_label(%Session{ended_at: nil}), do: "conectado"
  def reason_label(%Session{end_reason: "closed"}), do: "conexão encerrada"
  def reason_label(%Session{end_reason: "revoked"}), do: "revogado"
  def reason_label(%Session{end_reason: "crashed"}), do: "erro no canal"
  def reason_label(%Session{end_reason: "reconnected"}), do: "reconectou"
  def reason_label(%Session{end_reason: "restart"}), do: "control plane reiniciou"
  def reason_label(%Session{end_reason: "outdated"}), do: "recusado: versão"
  def reason_label(%Session{end_reason: "invalid_hello"}), do: "recusado: hello inválido"
  def reason_label(%Session{end_reason: other}), do: other

  defp reason_color(%Session{ended_at: nil}), do: "success"

  defp reason_color(%Session{end_reason: reason})
       when reason in ~w(crashed outdated invalid_hello), do: "danger"

  defp reason_color(%Session{end_reason: "closed"}), do: "warning"
  defp reason_color(_session), do: "gray"

  defp session_icon(%Session{ended_at: nil}), do: "hero-signal"

  defp session_icon(session),
    do: if(Session.refused?(session), do: "hero-no-symbol", else: "hero-signal-slash")

  defp session_color(%Session{ended_at: nil}), do: "text-success-500"

  defp session_color(session),
    do: if(Session.refused?(session), do: "text-danger-500", else: "text-gray-400")

  defp duration_ms(%Session{started_at: started, ended_at: ended}, now),
    do: DateTime.diff(ended || now, started, :millisecond)

  # The online stretches of the week, as {left, width} in percent of it.
  defp band(sessions, since, now) do
    total = DateTime.diff(now, since, :millisecond)

    for %Session{started_at: started, ended_at: ended} = session <- sessions,
        not Session.refused?(session),
        from = if(DateTime.compare(started, since) == :lt, do: since, else: started),
        to = ended || now,
        DateTime.compare(to, from) == :gt do
      # A stretch too short to see still shows, kept inside the band.
      width = max(DateTime.diff(to, from, :millisecond) / total * 100, 0.3)
      left = min(DateTime.diff(from, since, :millisecond) / total * 100, 100 - width)
      {Float.round(left, 3), Float.round(width, 3)}
    end
  end
end
