defmodule PipeMaestroWeb.RunnerLive.DoctorTab do
  @moduledoc """
  The runner page's "Diagnóstico" tab: the runner's latest diagnosis (its
  `doctor`, run after every connection, every hour and on request) and the
  button that asks for a new one, through its open connection.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]

  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner

  @doc "What the tab shows of `runner` as of `now`, online or not, with a request pending or not."
  @spec load(Runner.t(), boolean(), String.t() | nil, DateTime.t()) :: map()
  def load(%Runner{} = runner, online, pending, now) do
    doctor = runner.doctor || %{}

    %{
      capable: Runners.capable?(runner, "doctor"),
      outdated: runner.last_connected_at != nil and not Runners.capable?(runner, "doctor"),
      online: online,
      pending: pending,
      checks: doctor["checks"] || [],
      at: at(doctor["at"]),
      now: now
    }
  end

  attr :data, :map, required: true

  @doc "The tab."
  @spec doctor(map()) :: Phoenix.LiveView.Rendered.t()
  def doctor(assigns) do
    ~H"""
    <div class="space-y-6" data-testid="runner-doctor">
      <.alert :if={@data.outdated} color="warning" with_icon data-testid="runner-doctor-unsupported">
        Esta versão do runner não envia o diagnóstico. Atualize o runner, ou rode
        pipemaestro doctor na máquina dele.
      </.alert>

      <.card variant="outline">
        <.card_header title="Diagnóstico" description={description(@data)}>
          <:action>
            <.button
              size="sm"
              icon="hero-arrow-path"
              phx-click="run_doctor"
              disabled={!@data.online or !@data.capable or @data.pending != nil}
              data-testid="runner-doctor-run"
            >
              {if @data.pending, do: "Rodando…", else: "Rodar agora"}
            </.button>
          </:action>
        </.card_header>
        <.card_content>
          <p
            :if={@data.checks == []}
            class="text-sm text-gray-500 dark:text-gray-400"
            data-testid="runner-doctor-empty"
          >
            Nenhum diagnóstico ainda: o runner roda um ao conectar.
          </p>
          <ul :if={@data.checks != []} class="divide-y divide-gray-100 dark:divide-gray-800">
            <li
              :for={check <- @data.checks}
              class="flex flex-wrap items-start gap-x-3 gap-y-1 py-2 text-sm"
              data-testid={"runner-doctor-check-#{check["key"]}"}
            >
              <.icon
                name={status_icon(check["status"])}
                class={["mt-0.5 size-5 shrink-0", status_color(check["status"])]}
              />
              <span class="w-44 shrink-0 font-medium text-gray-900 dark:text-white">
                {check["name"]}
              </span>
              <span
                class="min-w-0 flex-1 break-words text-gray-600 dark:text-gray-300"
                data-testid={"runner-doctor-detail-#{check["key"]}"}
              >
                {check["detail"]}
              </span>
            </li>
          </ul>
        </.card_content>
      </.card>
    </div>
    """
  end

  defp description(%{at: nil, online: online}),
    do: "O que o runner confere na própria máquina." <> offline(online)

  defp description(%{at: at, now: now, online: online}),
    do:
      "O que o runner confere na própria máquina. Último: #{time_ago(at, now)}." <>
        offline(online)

  defp offline(true), do: ""
  defp offline(false), do: " Offline: o diagnóstico roda de novo quando ele conectar."

  defp status_icon("ok"), do: "hero-check-circle"
  defp status_icon("warning"), do: "hero-exclamation-triangle"
  defp status_icon(_error), do: "hero-x-circle"

  defp status_color("ok"), do: "text-success-500"
  defp status_color("warning"), do: "text-warning-500"
  defp status_color(_error), do: "text-danger-500"

  defp at(nil), do: nil

  defp at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _invalid -> nil
    end
  end
end
