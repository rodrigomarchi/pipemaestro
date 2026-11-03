defmodule ClaudeControlPlaneWeb.JobComponents do
  @moduledoc """
  Pieces every job screen shares: status, one event of the run (each tool
  call shown for what it is: a command, an edit as a diff, a file read), a
  colored diff, numbers.
  """
  use ClaudeControlPlaneWeb, :html

  alias ClaudeControlPlane.Jobs.{Event, Job}
  alias ClaudeControlPlaneWeb.Markdown

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

  @doc "One event of a run: an icon for its kind and what happened."
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
        <.event_body event={@event} body={@look.body} />
      </div>
    </li>
    """
  end

  attr :event, Event, required: true
  attr :body, :string, required: true

  defp event_body(%{event: %Event{type: "assistant_text"}} = assigns) do
    ~H"""
    <div class={[
      "prose prose-sm mt-1 max-w-none rounded-lg px-3 py-2 dark:prose-invert",
      "prose-h1:text-lg prose-h2:text-base prose-h3:text-sm",
      @body
    ]}>
      {Markdown.to_html(@event.data["text"])}
    </div>
    """
  end

  defp event_body(%{event: %Event{type: "tool_use", data: %{"input" => input}}} = assigns)
       when is_map(input) do
    assigns = assign(assigns, input: input, name: assigns.event.data["name"])
    tool_body(assigns)
  end

  defp event_body(%{event: %Event{type: "system"}} = assigns) do
    ~H"""
    <p class="mt-1 text-sm text-gray-700 dark:text-gray-300">
      {@event.data["text"]}
      <span :if={@event.data["auth"]} class="text-gray-500 dark:text-gray-400">
        · {auth_label(@event.data["auth"])}
      </span>
      <span
        :if={@event.data["permission_mode"]}
        class="font-mono text-xs text-gray-500 dark:text-gray-400"
      >
        · {@event.data["permission_mode"]}
      </span>
    </p>
    """
  end

  defp event_body(%{event: %Event{type: "tool_result"}} = assigns) do
    text = assigns.event.data["text"] || ""
    assigns = assign(assigns, text: text, lines: length(String.split(text, "\n")))

    ~H"""
    <details
      :if={@text != ""}
      open={@event.data["is_error"] == true}
      class="mt-1 text-xs"
    >
      <summary class="cursor-pointer text-gray-500 dark:text-gray-400">
        Saída · {lines_label(@lines)}
      </summary>
      <pre class={[
        "mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg px-3 py-2 font-mono",
        @body
      ]}>{@text}</pre>
    </details>
    """
  end

  defp event_body(assigns) do
    ~H"""
    <pre
      :if={@event.data["text"] not in [nil, ""]}
      class={[
        "mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg px-3 py-2 font-mono text-xs",
        @body
      ]}
    >{@event.data["text"]}</pre>
    """
  end

  defp tool_body(%{name: "Bash"} = assigns) do
    ~H"""
    <p :if={@input["description"]} class="mt-1 text-sm text-gray-700 dark:text-gray-300">
      {@input["description"]}
    </p>
    <pre class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-gray-900 px-3 py-2 font-mono text-xs text-gray-100 dark:bg-black">$ {@input["command"]}</pre>
    """
  end

  defp tool_body(%{name: "Edit"} = assigns) do
    assigns =
      assign(assigns,
        removed: lines(assigns.input["old_string"]),
        added: lines(assigns.input["new_string"])
      )

    ~H"""
    <p class="mt-1 break-all font-mono text-xs text-gray-700 dark:text-gray-300">
      {@input["file_path"]}
    </p>
    <pre class="mt-1 max-h-64 overflow-auto rounded-lg bg-gray-50 py-2 font-mono text-xs leading-5 dark:bg-gray-950"><code><span
      :for={line <- @removed}
      class={["block px-3", diff_class(:del)]}
    >-{line}</span><span
      :for={line <- @added}
      class={["block px-3", diff_class(:add)]}
    >+{line}</span></code></pre>
    """
  end

  defp tool_body(%{name: "Write"} = assigns) do
    ~H"""
    <details class="mt-1 text-xs">
      <summary class="cursor-pointer break-all font-mono text-gray-700 dark:text-gray-300">
        {@input["file_path"]}
      </summary>
      <pre class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-gray-50 px-3 py-2 font-mono text-gray-800 dark:bg-gray-950 dark:text-gray-100">{@input["content"]}</pre>
    </details>
    """
  end

  defp tool_body(%{name: "TodoWrite"} = assigns) do
    ~H"""
    <ul class="mt-1 space-y-0.5 text-sm">
      <li
        :for={todo <- @input["todos"] || []}
        data-status={todo["status"]}
        class="flex items-center gap-2 text-gray-800 dark:text-gray-200"
      >
        <.icon name={todo_icon(todo["status"])} class={["size-4", todo_color(todo["status"])]} />
        <span class={todo["status"] == "completed" && "text-gray-500 line-through"}>
          {todo["content"]}
        </span>
      </li>
    </ul>
    """
  end

  # Reads, searches and the rest: their arguments in one line.
  defp tool_body(assigns) do
    assigns = assign(assigns, parts: assigns.input |> Map.values() |> Enum.map(&to_string/1))

    ~H"""
    <p class="mt-1 break-all font-mono text-xs text-gray-700 dark:text-gray-300">
      {Enum.join(@parts, " · ")}
    </p>
    """
  end

  # The CLI's `apiKeySource`: "none" is the login of whoever ran `claude`.
  defp auth_label("none"), do: "login pessoal"
  defp auth_label(_source), do: "chave de API"

  defp lines(nil), do: []
  defp lines(text), do: String.split(text, "\n")

  defp lines_label(1), do: "1 linha"
  defp lines_label(n), do: "#{n} linhas"

  defp todo_icon("completed"), do: "hero-check-circle"
  defp todo_icon("in_progress"), do: "hero-arrow-path"
  defp todo_icon(_pending), do: "hero-stop-circle"

  defp todo_color("completed"), do: "text-success-600 dark:text-success-400"
  defp todo_color("in_progress"), do: "text-info-600 dark:text-info-400"
  defp todo_color(_pending), do: "text-gray-400"

  @doc "A unified diff, its added, removed and hunk lines colored."
  attr :patch, :string, required: true
  attr :rest, :global

  @spec patch(map()) :: Phoenix.LiveView.Rendered.t()
  def patch(assigns) do
    assigns = assign(assigns, lines: String.split(assigns.patch, "\n"))

    ~H"""
    <pre
      class="mt-3 max-h-[40rem] overflow-auto rounded-lg bg-gray-50 py-2 font-mono text-xs leading-5 dark:bg-gray-950"
      {@rest}
    ><code><span :for={line <- @lines} class={["block px-3", line_class(line)]}>{line}</span></code></pre>
    """
  end

  defp line_class("+++" <> _rest), do: "font-semibold text-gray-700 dark:text-gray-300"
  defp line_class("---" <> _rest), do: "font-semibold text-gray-700 dark:text-gray-300"

  defp line_class("+" <> _rest), do: diff_class(:add)
  defp line_class("-" <> _rest), do: diff_class(:del)

  defp line_class("@@" <> _rest), do: "text-info-700 dark:text-info-400"
  defp line_class("diff --git" <> _rest), do: "mt-2 font-semibold text-gray-900 dark:text-white"
  defp line_class(_line), do: "text-gray-700 dark:text-gray-300"

  defp diff_class(:add),
    do: "diff-add bg-success-50 text-success-800 dark:bg-success-950/40 dark:text-success-300"

  defp diff_class(:del),
    do: "diff-del bg-danger-50 text-danger-800 dark:bg-danger-950/40 dark:text-danger-300"

  @doc "What the agent is writing right now, before the full message arrives."
  attr :text, :string, required: true

  @spec typing(map()) :: Phoenix.LiveView.Rendered.t()
  def typing(assigns) do
    ~H"""
    <div class="mt-4 flex gap-3" data-testid="job-typing">
      <div class="mt-0.5 flex size-7 shrink-0 animate-pulse items-center justify-center rounded-full bg-primary-100 text-primary-700 dark:bg-primary-900/50 dark:text-primary-300">
        <.icon name="hero-pencil" class="size-4" />
      </div>
      <div class="min-w-0 flex-1">
        <p class="text-xs font-medium text-gray-500 dark:text-gray-400">Agente · escrevendo…</p>
        <p class="mt-1 whitespace-pre-wrap break-words rounded-lg bg-primary-50 px-3 py-2 text-sm text-gray-900 dark:bg-primary-950/40 dark:text-gray-100">
          {@text}
        </p>
      </div>
    </div>
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
