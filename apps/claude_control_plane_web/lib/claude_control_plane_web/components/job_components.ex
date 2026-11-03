defmodule ClaudeControlPlaneWeb.JobComponents do
  @moduledoc "Pieces every job screen shares: status, one event of the run, numbers."
  use ClaudeControlPlaneWeb, :html

  alias ClaudeControlPlane.Jobs.{Event, Job}

  @doc "The job's status as a badge; a running job asked to stop shows it."
  attr :job, Job, required: true
  attr :rest, :global

  @spec job_status(map()) :: Phoenix.LiveView.Rendered.t()
  def job_status(assigns) do
    {label, color} = status_label(assigns.job)
    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <.badge size="sm" variant="soft" color={@color} dot label={@label} {@rest} />
    """
  end

  defp status_label(%Job{status: :running, cancel_requested_at: %DateTime{}}),
    do: {"Cancelando…", "warning"}

  defp status_label(%Job{status: :queued}), do: {"Na fila", "gray"}
  defp status_label(%Job{status: :running}), do: {"Executando", "info"}
  defp status_label(%Job{status: :succeeded}), do: {"Concluído", "success"}
  defp status_label(%Job{status: :failed}), do: {"Falhou", "danger"}
  defp status_label(%Job{status: :canceled}), do: {"Cancelado", "gray"}

  @doc "One event of a run: an icon for its kind and its text."
  attr :id, :string, required: true
  attr :event, Event, required: true

  @spec job_event(map()) :: Phoenix.LiveView.Rendered.t()
  def job_event(assigns) do
    assigns = assign(assigns, :look, event_look(assigns.event))

    ~H"""
    <li id={@id} class="flex gap-3" data-testid="job-event" data-type={@event.type}>
      <div class={[
        "mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full",
        @look.bubble
      ]}>
        <.icon name={@look.icon} class="size-4" />
      </div>
      <div class="min-w-0 flex-1">
        <p class="text-xs font-medium text-gray-500 dark:text-gray-400">
          {@look.label}
          <span :if={@event.data["name"]} class="font-mono">
            · {@event.data["name"]}
          </span>
        </p>
        <pre
          :if={@event.data["text"] not in [nil, ""]}
          class={[
            "mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg px-3 py-2 font-mono text-xs",
            @look.body
          ]}
        >{@event.data["text"]}</pre>
      </div>
    </li>
    """
  end

  @neutral "bg-gray-100 text-gray-800 dark:bg-gray-800 dark:text-gray-100"

  defp event_look(%Event{type: "system"}),
    do: %{
      icon: "hero-play",
      label: "Sessão",
      bubble: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
      body: @neutral
    }

  defp event_look(%Event{type: "assistant_text"}),
    do: %{
      icon: "hero-chat-bubble-left-ellipsis",
      label: "Agente",
      bubble: "bg-primary-100 text-primary-700 dark:bg-primary-900/50 dark:text-primary-300",
      body: "bg-primary-50 text-gray-900 dark:bg-primary-950/40 dark:text-gray-100"
    }

  defp event_look(%Event{type: "tool_use"}),
    do: %{
      icon: "hero-wrench-screwdriver",
      label: "Ferramenta",
      bubble:
        "bg-secondary-100 text-secondary-700 dark:bg-secondary-900/50 dark:text-secondary-300",
      body: @neutral
    }

  defp event_look(%Event{type: "tool_result", data: %{"is_error" => true}}),
    do: %{
      icon: "hero-exclamation-triangle",
      label: "Erro da ferramenta",
      bubble: "bg-danger-100 text-danger-700 dark:bg-danger-900/50 dark:text-danger-300",
      body: "bg-danger-50 text-danger-900 dark:bg-danger-950/40 dark:text-danger-100"
    }

  defp event_look(%Event{type: "tool_result"}),
    do: %{
      icon: "hero-arrow-uturn-left",
      label: "Resultado da ferramenta",
      bubble: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
      body: @neutral
    }

  defp event_look(%Event{}),
    do: %{
      icon: "hero-flag",
      label: "Fim da execução",
      bubble: "bg-success-100 text-success-700 dark:bg-success-900/50 dark:text-success-300",
      body: @neutral
    }

  @doc ~s(A duration in milliseconds, short: "850 ms", "12 s", "3 min 05 s".)
  @spec format_duration(non_neg_integer() | nil) :: String.t()
  def format_duration(nil), do: "—"
  def format_duration(ms) when ms < 1_000, do: "#{ms} ms"
  def format_duration(ms) when ms < 60_000, do: "#{div(ms, 1_000)} s"

  def format_duration(ms) do
    seconds = div(ms, 1_000)

    "#{div(seconds, 60)} min #{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")} s"
  end

  @doc ~s(A cost in US dollars with four decimals: "US$ 0.0037".)
  @spec format_cost(Decimal.t() | nil) :: String.t()
  def format_cost(nil), do: "—"

  def format_cost(%Decimal{} = cost),
    do: "US$ " <> (cost |> Decimal.round(4) |> Decimal.to_string(:normal))

  @doc "The first line of a prompt, cut to `max` characters."
  @spec prompt_summary(String.t(), pos_integer()) :: String.t()
  def prompt_summary(prompt, max \\ 80) do
    line = prompt |> String.split("\n", parts: 2) |> hd() |> String.trim()
    if String.length(line) > max, do: String.slice(line, 0, max - 1) <> "…", else: line
  end
end
