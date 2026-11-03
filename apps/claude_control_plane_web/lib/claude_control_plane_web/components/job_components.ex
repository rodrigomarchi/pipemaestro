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
    <li
      id={@id}
      class={["flex gap-3", @event.data["parent_tool_use_id"] && "ml-8"]}
      data-testid="job-event"
      data-type={@event.type}
    >
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
          <span :if={@event.data["parent_tool_use_id"]} class="font-normal">· subagente</span>
          <span :if={@event.data["usage"]} class="font-normal">
            · {tokens_label(@event.data["usage"])}
          </span>
          <span
            :if={get_in(@event.data, ["decision", "decision"]) == "reject"}
            class="font-normal text-danger-700 dark:text-danger-400"
          >
            · negada ({@event.data["decision"]["source"]})
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

  defp event_body(%{event: %Event{type: "thinking"}} = assigns) do
    ~H"""
    <details class="mt-1 text-sm">
      <summary class="cursor-pointer text-gray-500 dark:text-gray-400">
        Pensou por {format_duration(@event.data["duration_ms"])}
      </summary>
      <p
        :if={@event.data["text"] in [nil, ""]}
        class="mt-1 text-xs text-gray-500 dark:text-gray-400"
      >
        O CLI não mostra o raciocínio nesta execução, só quanto tempo levou.
      </p>
      <pre
        :if={@event.data["text"] not in [nil, ""]}
        class={[
          "mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg px-3 py-2 font-sans text-xs",
          @body
        ]}
      >{@event.data["text"]}</pre>
    </details>
    """
  end

  defp event_body(%{event: %Event{type: "compact"}} = assigns) do
    ~H"""
    <p class="mt-1 text-sm text-gray-700 dark:text-gray-300">
      {@event.data["text"]}
      <span :if={@event.data["pre_tokens"]} class="text-gray-500 dark:text-gray-400">
        · tinha {short_number(@event.data["pre_tokens"])} tokens
      </span>
    </p>
    """
  end

  defp event_body(%{event: %Event{type: "rate_limit"}} = assigns) do
    ~H"""
    <p class="mt-1 text-sm text-gray-700 dark:text-gray-300">
      {@event.data["status"]}
      <span :for={{window, used} <- Enum.sort(@event.data["utilization"] || %{})}>
        · {window} {round(used * 100)}%
      </span>
    </p>
    """
  end

  defp event_body(%{event: %Event{type: "permission_denied"}} = assigns) do
    ~H"""
    <p class="mt-1 text-sm text-danger-700 dark:text-danger-400">
      <span :if={@event.data["tool_name"]} class="font-mono">{@event.data["tool_name"]}:</span>
      {@event.data["text"]}
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

  @doc ~s(How the CLI signed in, from its `apiKeySource`: "none" is the login of whoever ran `claude`.)
  @spec auth_label(String.t() | nil) :: String.t()
  def auth_label(nil), do: "—"
  def auth_label("none"), do: "login pessoal"
  def auth_label(_source), do: "chave de API"

  @doc ~s(A share from 0 to 1 as a percentage: "91%".)
  @spec format_percent(float() | nil) :: String.t()
  def format_percent(nil), do: "—"
  def format_percent(share), do: "#{round(share * 100)}%"

  # A message's tokens carry their input summed; the run's totals (on the
  # result) carry its parts.
  defp tokens_label(%{"input" => input} = usage),
    do: "#{short_number(input)} → #{short_number(usage["output"] || 0)} tokens"

  defp tokens_label(usage) do
    input =
      ~w(fresh_input cache_read cache_creation) |> Enum.map(&(usage[&1] || 0)) |> Enum.sum()

    "#{short_number(input)} → #{short_number(usage["output"] || 0)} tokens"
  end

  @doc ~s(A count, short: "850", "12.3k", "4.1M".)
  @spec short_number(number() | nil) :: String.t()
  def short_number(nil), do: "—"
  def short_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def short_number(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  def short_number(n), do: to_string(n)

  @reading_tools ~w(Read Grep Glob LS)

  @doc """
  A finished run's events as the steps screen shows them, after `filter`
  (`"all"`; `"agent"`: what the agent said; `"tools"`: tool calls and their
  answers; `"thinking"`: what the model thought; `"errors"`: what failed,
  retried or was refused): `{:event, event}`, or `{:group, label,
  events}` for two or more consecutive reads and searches with their answers.
  """
  @spec timeline_items([Event.t()], String.t()) ::
          [{:event, Event.t()} | {:group, String.t(), [Event.t()]}]
  def timeline_items(events, filter) do
    {items, run} =
      events
      |> Enum.filter(&shown?(&1, filter))
      |> Enum.reduce({[], []}, fn event, {items, run} ->
        if reading?(event) or answers_read?(event, run),
          do: {items, [event | run]},
          else: {[{:event, event} | flush(run, items)], []}
      end)

    run |> flush(items) |> Enum.reverse()
  end

  defp shown?(%Event{type: type}, "agent"), do: type in ~w(system assistant_text result)
  defp shown?(%Event{type: type}, "tools"), do: type in ~w(tool_use tool_result)
  defp shown?(%Event{type: type}, "thinking"), do: type == "thinking"

  defp shown?(%Event{type: type, data: data}, "errors"),
    do: data["is_error"] == true or type in ~w(api_retry permission_denied)

  defp shown?(_event, _all), do: true

  defp reading?(%Event{type: "tool_use", data: %{"name" => name}}), do: name in @reading_tools
  defp reading?(_event), do: false

  # The answer right after a read (an error stays on its own).
  defp answers_read?(%Event{type: "tool_result", data: data}, [last | _run]),
    do: reading?(last) and data["is_error"] != true

  defp answers_read?(_event, _run), do: false

  # A run of two or more reads becomes a group; a single one stays as it is.
  defp flush(run, items) do
    calls = Enum.filter(run, &reading?/1)

    if length(calls) >= 2,
      do: [{:group, reading_label(calls), Enum.reverse(run)} | items],
      else: Enum.map(run, &{:event, &1}) ++ items
  end

  defp reading_label(calls) do
    {reads, searches} = Enum.split_with(calls, &(&1.data["name"] == "Read"))

    [
      reads != [] && "Leu #{count_label(length(reads), "arquivo", "arquivos")}",
      searches != [] && "fez #{count_label(length(searches), "busca", "buscas")}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" e ")
    |> String.capitalize()
  end

  @doc ~s(A count with its noun: "1 arquivo", "3 arquivos".)
  @spec count_label(non_neg_integer(), String.t(), String.t()) :: String.t()
  def count_label(1, one, _many), do: "1 #{one}"
  def count_label(n, _one, many), do: "#{n} #{many}"

  @doc "A finished run's steps: events, and groups of reads that open to show theirs."
  attr :items, :list, required: true
  attr :id, :string, required: true

  @spec steps(map()) :: Phoenix.LiveView.Rendered.t()
  def steps(assigns) do
    ~H"""
    <ol class="mt-3 space-y-3" data-testid={"stage-run-steps-#{@id}"}>
      <%= for item <- @items do %>
        <.job_event
          :if={match?({:event, _}, item)}
          id={"step-#{elem(item, 1).id}"}
          event={elem(item, 1)}
        />
        <li :if={match?({:group, _, _}, item)} class="flex gap-3" data-testid="job-event-group">
          <div class="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400">
            <.icon name="hero-document-magnifying-glass" class="size-4" />
          </div>
          <details class="min-w-0 flex-1 text-sm">
            <summary class="cursor-pointer text-gray-700 dark:text-gray-300">{elem(item, 1)}</summary>
            <ol class="mt-3 space-y-3">
              <.job_event :for={event <- elem(item, 2)} id={"step-#{event.id}"} event={event} />
            </ol>
          </details>
        </li>
      <% end %>
    </ol>
    """
  end

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

  defp event_look(%Event{type: "thinking"}),
    do: %{
      icon: "hero-light-bulb",
      label: "Pensou",
      bubble: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
      body: @neutral
    }

  defp event_look(%Event{type: "api_retry"}),
    do: %{
      icon: "hero-arrow-path",
      label: "Nova tentativa da API",
      bubble: "bg-warning-100 text-warning-700 dark:bg-warning-900/50 dark:text-warning-300",
      body: "bg-warning-50 text-warning-900 dark:bg-warning-950/40 dark:text-warning-100"
    }

  defp event_look(%Event{type: "compact"}),
    do: %{
      icon: "hero-archive-box-arrow-down",
      label: "Compactação",
      bubble: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
      body: @neutral
    }

  defp event_look(%Event{type: "permission_denied"}),
    do: %{
      icon: "hero-no-symbol",
      label: "Permissão negada",
      bubble: "bg-danger-100 text-danger-700 dark:bg-danger-900/50 dark:text-danger-300",
      body: @neutral
    }

  defp event_look(%Event{type: "rate_limit"}),
    do: %{
      icon: "hero-chart-bar",
      label: "Limites da conta",
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
  @spec format_cost(Decimal.t() | number() | nil) :: String.t()
  def format_cost(nil), do: "—"

  def format_cost(%Decimal{} = cost),
    do: "US$ " <> (cost |> Decimal.round(4) |> Decimal.to_string(:normal))

  def format_cost(cost) when is_float(cost), do: cost |> Decimal.from_float() |> format_cost()
  def format_cost(cost) when is_integer(cost), do: cost |> Decimal.new() |> format_cost()

  @doc "The first line of a prompt, cut to `max` characters."
  @spec prompt_summary(String.t(), pos_integer()) :: String.t()
  def prompt_summary(prompt, max \\ 80) do
    line = prompt |> String.split("\n", parts: 2) |> hd() |> String.trim()
    if String.length(line) > max, do: String.slice(line, 0, max - 1) <> "…", else: line
  end
end
