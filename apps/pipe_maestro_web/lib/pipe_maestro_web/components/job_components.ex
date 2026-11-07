defmodule PipeMaestroWeb.JobComponents do
  @moduledoc """
  Pieces every job screen shares: status, the run's timeline, a colored diff,
  numbers.

  The timeline is a list of segments (`timeline_items/2`, `timeline_push/2`
  for a live run): strips of small icons for the events without text to read
  (the session, thinking, tool calls and their results, limits, retries,
  compactions, denials), each with a one-line tooltip and colored by state,
  and blocks for the agent's text and the run's result. Clicking an icon opens,
  below its strip, a panel with the event in full (each tool call shown for
  what it is: a command, an edit as a diff, a file read); the panels open and
  close in the browser (`Phoenix.LiveView.JS`), so an open panel stays open
  while its strip grows.
  """
  use PipeMaestroWeb, :html

  # `timeline/1` here is the run's timeline, not Petal's.
  import PetalComponents.Timeline, only: []
  import PipeMaestroWeb.AgentOutput, only: [agent_output: 1]

  alias PipeMaestro.Jobs.{Event, Job}
  alias PipeMaestroWeb.Markdown

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

  @typedoc """
  A piece of the timeline: a strip of icons (events without text to read, side
  by side) or a block of the agent's text. Its `id` comes from its first event,
  so a strip keeps it while it grows.
  """
  @type segment :: %{id: String.t(), kind: :strip | :text, events: [Event.t()]}

  @typedoc """
  What a live timeline needs to place the next event: the strip still open at
  its end, the `seq`s already shown, and the filter that names new strips.
  """
  @type tail :: %{strip: segment() | nil, seen: MapSet.t(integer()), filter: String.t()}

  @text_types ~w(assistant_text result)

  @doc "Whether an event is shown as an icon: all but the agent's text and the run's result."
  @spec icon?(Event.t()) :: boolean()
  def icon?(%Event{type: type}), do: type not in @text_types

  @doc """
  How an icon is colored: `:error` for a failed tool and an API retry,
  `:denied` for a refused permission, `:normal` for the rest.
  """
  @spec event_state(Event.t()) :: :normal | :error | :denied
  def event_state(%Event{type: "permission_denied"}), do: :denied

  def event_state(%Event{type: type, data: data}) do
    cond do
      get_in(data, ["decision", "decision"]) == "reject" -> :denied
      type == "api_retry" or data["is_error"] == true -> :error
      true -> :normal
    end
  end

  @doc """
  An event in one line, for an icon's tooltip: what a tool did (a command's
  purpose, a path, a pattern), a result's size, how long the model thought;
  then the turn's tokens and whether a subagent did it.
  """
  @spec event_summary(Event.t()) :: String.t()
  def event_summary(%Event{data: data} = event) do
    join_parts([
      base_summary(event),
      data["usage"] && tokens_label(data["usage"]),
      data["parent_tool_use_id"] && "subagente"
    ])
  end

  defp base_summary(%Event{type: "tool_use", data: data}) do
    detail = tool_detail(data["name"], data["input"]) || data["text"]
    join_parts([data["name"], detail && prompt_summary(detail)])
  end

  defp base_summary(%Event{type: "tool_result", data: data}) do
    text = data["text"] || ""

    cond do
      get_in(data, ["decision", "decision"]) == "reject" ->
        "Negada (#{data["decision"]["source"]})"

      text == "" ->
        "Sem saída"

      data["is_error"] == true ->
        "Erro · #{lines_label(length(lines(text)))}"

      true ->
        "Saída · #{lines_label(length(lines(text)))}"
    end
  end

  defp base_summary(%Event{type: "thinking", data: data}),
    do: "Pensou por #{format_duration(data["duration_ms"])}"

  defp base_summary(%Event{type: "system", data: data}),
    do: join_parts([data["text"], data["auth"] && auth_label(data["auth"])])

  defp base_summary(%Event{type: "rate_limit", data: data}),
    do: join_parts([data["status"] | utilization_labels(data["utilization"])])

  defp base_summary(%Event{type: "compact", data: data}) do
    join_parts([
      data["text"],
      data["pre_tokens"] && "tinha #{short_number(data["pre_tokens"])} tokens"
    ])
  end

  defp base_summary(%Event{type: "permission_denied", data: data}) do
    if data["tool_name"],
      do: "#{data["tool_name"]}: #{data["text"]}",
      else: data["text"] || ""
  end

  defp base_summary(%Event{type: type, data: data}),
    do: if(data["text"] in [nil, ""], do: type, else: prompt_summary(data["text"]))

  defp tool_detail("Bash", %{} = input),
    do: input["description"] || input["command"]

  defp tool_detail(name, %{} = input) when name in ~w(Read Edit Write), do: input["file_path"]
  defp tool_detail(name, %{} = input) when name in ~w(Grep Glob), do: input["pattern"]
  defp tool_detail(_name, _input), do: nil

  defp utilization_labels(utilization),
    do:
      for({window, used} <- Enum.sort(utilization || %{}), do: "#{window} #{round(used * 100)}%")

  defp join_parts(parts),
    do: parts |> Enum.reject(&(&1 in [nil, false, ""])) |> Enum.join(" · ")

  @doc """
  A run's events as segments, after `filter` (`"all"`; `"agent"`: what the
  agent said; `"tools"`: tool calls and their answers; `"thinking"`: what the
  model thought; `"errors"`: what failed, retried or was refused). Consecutive
  icons share a strip; the agent's text is a block of its own and breaks the
  strip. The filter is part of a strip's id, so another filter shows other
  strips.
  """
  @spec timeline_items([Event.t()], String.t()) :: [segment()]
  def timeline_items(events, filter) do
    {segments, _tail} =
      events
      |> Enum.filter(&shown?(&1, filter))
      |> Enum.reduce({[], new_tail(filter)}, fn event, {segments, tail} ->
        case timeline_push(tail, event) do
          {:seen, tail} -> {segments, tail}
          {segment, tail} -> {put_segment(segments, segment), tail}
        end
      end)

    Enum.reverse(segments)
  end

  defp put_segment([%{id: id} | rest], %{id: id} = segment), do: [segment | rest]
  defp put_segment(segments, segment), do: [segment | segments]

  defp new_tail(filter), do: %{strip: nil, seen: MapSet.new(), filter: filter}

  @doc "Where a live timeline stands after `segments`, read when the page opened."
  @spec timeline_tail([segment()]) :: tail()
  def timeline_tail(segments) do
    last = List.last(segments)

    %{
      new_tail("all")
      | strip: if(match?(%{kind: :strip}, last), do: last),
        seen:
          for(%{events: events} <- segments, event <- events, into: MapSet.new(), do: event.seq)
    }
  end

  @doc """
  Places one more event at the end of a live timeline: the segment to insert
  (the open strip grown by an icon, a new strip, or a text block) and the new
  tail; `:seen` for an event already shown.
  """
  @spec timeline_push(tail(), Event.t()) :: {segment() | :seen, tail()}
  def timeline_push(%{seen: seen} = tail, %Event{seq: seq} = event) do
    cond do
      MapSet.member?(seen, seq) ->
        {:seen, tail}

      icon?(event) ->
        strip =
          case tail.strip do
            nil -> %{id: "strip-#{tail.filter}-#{event.id}", kind: :strip, events: [event]}
            strip -> %{strip | events: strip.events ++ [event]}
          end

        {strip, %{tail | strip: strip, seen: MapSet.put(seen, seq)}}

      true ->
        text = %{id: "text-#{event.id}", kind: :text, events: [event]}
        {text, %{tail | strip: nil, seen: MapSet.put(seen, seq)}}
    end
  end

  @doc """
  A run's timeline: strips of icons and blocks of text. Each icon opens, below
  its strip, a panel with the event in full; one panel is open at a time per
  timeline.
  """
  attr :id, :string, required: true
  attr :segments, :list, required: true
  attr :class, :any, default: "space-y-3"
  attr :rest, :global

  @spec timeline(map()) :: Phoenix.LiveView.Rendered.t()
  def timeline(assigns) do
    ~H"""
    <ol id={@id} class={@class} {@rest}>
      <.timeline_segment
        :for={segment <- @segments}
        id={"#{@id}-#{segment.id}"}
        timeline={@id}
        segment={segment}
      />
    </ol>
    """
  end

  @doc """
  One segment of a timeline, `id` its DOM id and `timeline` the id of the list
  it is in (a stream's container, for a live run).
  """
  attr :id, :string, required: true
  attr :timeline, :string, required: true
  attr :segment, :map, required: true

  @spec timeline_segment(map()) :: Phoenix.LiveView.Rendered.t()
  def timeline_segment(%{segment: %{kind: :strip, events: [first | _]}} = assigns) do
    assigns = assign(assigns, :first, first)

    ~H"""
    <li id={@id} data-testid={"job-event-strip-#{@first.seq}"}>
      <div class="flex flex-wrap items-center gap-1">
        <.event_icon
          :for={event <- @segment.events}
          id={"#{@id}-icon-#{event.id}"}
          panel_id={"#{@id}-panel-#{event.id}"}
          timeline={@timeline}
          event={event}
        />
      </div>
      <.event_panel
        :for={event <- @segment.events}
        id={"#{@id}-panel-#{event.id}"}
        event={event}
      />
    </li>
    """
  end

  def timeline_segment(%{segment: %{kind: :text, events: [event]}} = assigns) do
    assigns = assign(assigns, event: event, look: event_look(event))

    ~H"""
    <li
      id={@id}
      class={["flex gap-3", @event.data["parent_tool_use_id"] && "ml-8"]}
      data-testid={"job-event-#{@event.seq}"}
      data-type={@event.type}
    >
      <div class={[
        "mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full",
        @look.bubble
      ]}>
        <.icon name={@look.icon} class="size-4" />
      </div>
      <div class="min-w-0 flex-1">
        <.event_header event={@event} look={@look} />
        <.event_body id={"#{@id}-body"} event={@event} body={@look.body} />
      </div>
    </li>
    """
  end

  @open_icon "ring-2 ring-primary-500 dark:ring-primary-400"

  attr :id, :string, required: true
  attr :panel_id, :string, required: true
  attr :timeline, :string, required: true
  attr :event, Event, required: true

  defp event_icon(assigns) do
    event = assigns.event
    summary = event_summary(event)
    look = event_look(event)
    state = event_state(event)

    assigns =
      assign(assigns,
        look: look,
        state: state,
        summary: summary,
        subagent: event.data["parent_tool_use_id"] != nil
      )

    ~H"""
    <.icon_button
      id={@id}
      type="button"
      size="xs"
      color={if @state == :normal, do: "gray", else: "danger"}
      tooltip={@summary}
      class={@subagent && "outline-dashed outline-1 outline-offset-1 outline-gray-400"}
      aria-label={"#{@look.label}: #{@summary}"}
      aria-expanded="false"
      aria-controls={@panel_id}
      phx-click={toggle_panel(@timeline, @id, @panel_id)}
      data-testid={"job-event-icon-#{@event.seq}"}
      data-type={@event.type}
      data-state={@state}
      data-subagent={@subagent}
      data-event-icon
    >
      <.icon name={@look.icon} class="size-4" />
    </.icon_button>
    """
  end

  # Opens an icon's panel and closes any other of the same timeline; the same
  # icon again closes it.
  defp toggle_panel(timeline, icon_id, panel_id) do
    other_icons = "##{timeline} [data-event-icon]:not(##{icon_id})"

    JS.hide(to: "##{timeline} [data-event-panel]:not(##{panel_id})")
    |> JS.remove_class(@open_icon, to: other_icons)
    |> JS.set_attribute({"aria-expanded", "false"}, to: other_icons)
    |> JS.toggle(to: "##{panel_id}")
    |> JS.toggle_class(@open_icon, to: "##{icon_id}")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{icon_id}")
  end

  attr :id, :string, required: true
  attr :event, Event, required: true

  defp event_panel(assigns) do
    assigns = assign(assigns, :look, event_look(assigns.event))

    ~H"""
    <div
      id={@id}
      class={[
        "hidden mt-2 rounded-lg border border-gray-200 px-3 py-2 dark:border-gray-700",
        @event.data["parent_tool_use_id"] && "border-dashed"
      ]}
      data-testid={"job-event-panel-#{@event.seq}"}
      data-type={@event.type}
      data-event-panel
    >
      <.event_header event={@event} look={@look} />
      <.event_body id={"#{@id}-body"} event={@event} body={@look.body} />
    </div>
    """
  end

  attr :event, Event, required: true
  attr :look, :map, required: true

  defp event_header(assigns) do
    ~H"""
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
    """
  end

  attr :id, :string, required: true
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

  defp event_body(%{event: %Event{type: "result", data: %{"text" => text}}} = assigns)
       when is_binary(text) and text != "" do
    ~H"""
    <.agent_output
      id={"#{@id}-output"}
      text={@event.data["text"]}
      class={["mt-1 max-h-[32rem] overflow-auto rounded-lg px-3 py-2", @body]}
    />
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
    <div class="mt-1 text-sm">
      <p class="text-gray-500 dark:text-gray-400">
        Pensou por {format_duration(@event.data["duration_ms"])}
      </p>
      <p
        :if={@event.data["text"] in [nil, ""]}
        class="mt-1 text-xs text-gray-500 dark:text-gray-400"
      >
        O CLI não mostra o raciocínio nesta execução, só quanto tempo levou.
      </p>
      <div
        :if={@event.data["text"] not in [nil, ""]}
        class={[
          "prose prose-sm mt-1 max-h-64 max-w-none overflow-auto rounded-lg px-3 py-2 dark:prose-invert",
          @body
        ]}
      >
        {Markdown.to_html(@event.data["text"])}
      </div>
    </div>
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
      <span :for={window <- utilization_labels(@event.data["utilization"])}>· {window}</span>
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
    assigns = assign(assigns, text: text, lines: length(lines(text)))

    ~H"""
    <p :if={@text == ""} class="mt-1 text-xs text-gray-500 dark:text-gray-400">Sem saída.</p>
    <div :if={@text != ""} class="mt-1 text-xs">
      <p class="text-gray-500 dark:text-gray-400">Saída · {lines_label(@lines)}</p>
      <pre class={[
        "mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-lg px-3 py-2 font-mono",
        @body
      ]}>{@text}</pre>
    </div>
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

  # Reads, searches and the rest: short arguments in one line; long text (a
  # plan, a subagent's prompt) as Markdown; lists and maps as indented JSON.
  defp tool_body(assigns) do
    {short, long, structured} = split_input(assigns.input)
    assigns = assign(assigns, short: short, long: long, structured: structured)

    ~H"""
    <p
      :if={@short != []}
      class="mt-1 break-all font-mono text-xs text-gray-700 dark:text-gray-300"
    >
      {Enum.join(@short, " · ")}
    </p>
    <div :for={{key, text} <- @long} class="mt-1" data-input={key}>
      <p class="text-xs text-gray-500 dark:text-gray-400">{key}</p>
      <div class="prose prose-sm max-h-80 max-w-none overflow-auto rounded-lg bg-gray-50 px-3 py-2 dark:prose-invert dark:bg-gray-950">
        {Markdown.to_html(text)}
      </div>
    </div>
    <div :for={{key, value} <- @structured} class="mt-1" data-input={key}>
      <p class="text-xs text-gray-500 dark:text-gray-400">{key}</p>
      <pre class="max-h-64 overflow-auto rounded-lg bg-gray-50 px-3 py-2 text-xs dark:bg-gray-950"><code class="language-json text-gray-800 dark:text-gray-100">{Jason.encode!(value, pretty: true)}</code></pre>
    </div>
    """
  end

  # A text is long when it has more than a line or would not fit in one.
  defp split_input(input) do
    input
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], [], []}, fn {key, value}, {short, long, structured} ->
      cond do
        is_nil(value) or value == "" ->
          {short, long, structured}

        is_binary(value) and (String.contains?(value, "\n") or String.length(value) > 160) ->
          {short, [{key, value} | long], structured}

        is_map(value) or is_list(value) ->
          {short, long, [{key, value} | structured]}

        true ->
          {[to_string(value) | short], long, structured}
      end
    end)
    |> then(fn {short, long, structured} ->
      {Enum.reverse(short), Enum.reverse(long), Enum.reverse(structured)}
    end)
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

  defp shown?(%Event{type: type}, "agent"), do: type in ~w(system assistant_text result)
  defp shown?(%Event{type: type}, "tools"), do: type in ~w(tool_use tool_result)
  defp shown?(%Event{type: type}, "thinking"), do: type == "thinking"

  defp shown?(%Event{type: type, data: data}, "errors"),
    do: data["is_error"] == true or type in ~w(api_retry permission_denied)

  defp shown?(_event, _all), do: true

  @doc ~s(A count with its noun: "1 arquivo", "3 arquivos".)
  @spec count_label(non_neg_integer(), String.t(), String.t()) :: String.t()
  def count_label(1, one, _many), do: "1 #{one}"
  def count_label(n, _one, many), do: "#{n} #{many}"

  @doc "A finished run's steps (`items` from `timeline_items/2`) as a timeline of their own."
  attr :items, :list, required: true
  attr :id, :string, required: true

  @spec steps(map()) :: Phoenix.LiveView.Rendered.t()
  def steps(assigns) do
    ~H"""
    <.timeline
      id={"steps-#{@id}"}
      segments={@items}
      class="mt-3 space-y-3"
      data-testid={"stage-run-steps-#{@id}"}
    />
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

  defp event_look(%Event{type: "result"}),
    do: %{
      icon: "hero-flag",
      label: "Fim da execução",
      bubble: "bg-success-100 text-success-700 dark:bg-success-900/50 dark:text-success-300",
      body: @neutral
    }

  defp event_look(%Event{type: type}),
    do: %{
      icon: "hero-ellipsis-horizontal-circle",
      label: type,
      bubble: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400",
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

  @doc """
  The first line of a prompt with text, cut to `max` characters, without its
  Markdown marks (a heading's `#`, a list's `-`, emphasis and code ticks).
  """
  @spec prompt_summary(String.t(), pos_integer()) :: String.t()
  def prompt_summary(prompt, max \\ 80) do
    line =
      prompt
      |> String.split("\n")
      |> Enum.map(&plain_line/1)
      |> Enum.find("", &(&1 != ""))

    if String.length(line) > max, do: String.slice(line, 0, max - 1) <> "…", else: line
  end

  defp plain_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/^(#+|>|[-*+]|\d+\.)\s+/, "")
    |> String.replace(~r/\*\*(\S.*?)\*\*|`([^`]+)`/, "\\1\\2")
    |> String.trim()
  end
end
