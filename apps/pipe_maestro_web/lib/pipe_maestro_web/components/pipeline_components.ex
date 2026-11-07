defmodule PipeMaestroWeb.PipelineComponents do
  @moduledoc """
  The pieces a pipeline is shown with, shared by its page
  (`PipeMaestroWeb.PipelineLive.Show`), its editor
  (`PipeMaestroWeb.PipelineLive.Form`) and the list
  (`PipeMaestroWeb.PipelineLive.Index`).

  `pipeline_diagram/1` draws a `PipeMaestroWeb.PipelineDiagram` as connected
  nodes: the entry, each step (a group forks to its stages and joins after
  them), the delivery and the end, and under them the rail of the places a
  task stops for a person. It lays out as a grid, one column per node or
  connector: the second row holds each step's edges to the rail, the third
  the rail. In `:read` mode a node is selected (`select_node`); `:edit` adds
  the structure's buttons (`insert_stage`, `move_stage`, `remove_stage`,
  `join_group`, `leave_group`); `:compact` is an inert preview, and `:micro`
  a row of dots, one per stage, for where a task is. The diagram's layers
  (a task's states, metrics, a comparison) show on the nodes; with `link`,
  a node is a link (to a stage on the page) instead of opening a panel.

  A stage's state has one vocabulary across the product: `state_label/1`,
  `stage_state_badge/1` and `stage_state_marker/1`.

  `side_panel/1` is a panel fixed to the right edge. Unlike Petal's
  `slide_over`, which only opens when mounted, it stays in the page while
  closed (hidden), so a form's inputs inside it keep being sent.
  """
  use PipeMaestroWeb, :html

  alias PipeMaestro.Pipelines.{Json, Pipeline, Stage}
  alias PipeMaestroWeb.{Markdown, PipelineDiagram}

  @doc "What a delivery is called."
  @spec delivery_label(String.t() | nil) :: String.t()
  def delivery_label("pr"), do: "Pull request"
  def delivery_label("commit"), do: "Commits conferidos"
  def delivery_label(_none), do: "Sem entrega"

  @doc "A delivery's icon."
  @spec delivery_icon(String.t() | nil) :: String.t()
  def delivery_icon("pr"), do: "hero-rocket-launch"
  def delivery_icon("commit"), do: "hero-check-badge"
  def delivery_icon(_none), do: "hero-no-symbol"

  @doc "A task's cost cap, as a person reads it."
  @spec budget_label(Decimal.t() | nil) :: String.t()
  def budget_label(nil), do: "Sem limite de custo"
  def budget_label(cost), do: "Até US$ #{cost}"

  # ── A stage's state ───────────────────────────────────────────────────────

  @states %{
    pending: {"Aguardando", "gray"},
    running: {"Executando", "info"},
    awaiting: {"Aguardando decisão", "warning"},
    passed: {"Concluída", "success"},
    blocked: {"Bloqueada", "warning"},
    failed: {"Falhou", "danger"},
    canceled: {"Cancelada", "gray"}
  }

  @doc "What a stage's state is called (`PipeMaestroWeb.PipelineDiagram.task_states/1`)."
  @spec state_label(atom()) :: String.t()
  def state_label(state), do: @states |> Map.fetch!(state) |> elem(0)

  defp state_color(state), do: @states |> Map.fetch!(state) |> elem(1)

  attr :state, :atom, required: true
  attr :rest, :global

  @doc "A stage's state as a badge."
  def stage_state_badge(assigns) do
    assigns =
      assign(assigns, label: state_label(assigns.state), color: state_color(assigns.state))

    ~H"""
    <.badge size="xs" variant="soft" color={@color} label={@label} {@rest} />
    """
  end

  attr :state, :atom, required: true
  attr :number, :integer, required: true
  attr :class, :any, default: "size-8 text-sm ring-4 ring-gray-50 dark:ring-gray-950"

  @doc "A stage's number, or its state as an icon once it ran."
  def stage_state_marker(assigns) do
    ~H"""
    <span class={[
      "relative z-10 flex shrink-0 items-center justify-center rounded-full font-semibold",
      marker_class(@state),
      @class
    ]}>
      <.icon :if={@state == :passed} name="hero-check" class="size-4" />
      <.icon :if={@state in [:failed, :canceled]} name="hero-x-mark" class="size-4" />
      <.icon :if={@state in [:awaiting, :blocked]} name="hero-hand-raised" class="size-4" />
      <.icon :if={@state == :running} name="hero-arrow-path" class="size-4 animate-spin" />
      <span :if={@state == :pending}>{@number}</span>
    </span>
    """
  end

  defp marker_class(:passed), do: "bg-success-500 text-white"
  defp marker_class(:running), do: "bg-info-500 text-white"
  defp marker_class(state) when state in [:awaiting, :blocked], do: "bg-warning-400 text-gray-900"
  defp marker_class(state) when state in [:failed, :canceled], do: "bg-danger-500 text-white"

  defp marker_class(:pending),
    do: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"

  # ── The diagram ────────────────────────────────────────────────────────────

  attr :diagram, :map, required: true, doc: "a `PipeMaestroWeb.PipelineDiagram`"
  attr :mode, :atom, default: :read, values: [:read, :edit, :compact, :micro]

  attr :selected, :any,
    default: nil,
    doc: "`:entry`, `{:stage, index}` or nil: the node whose panel is open"

  attr :link, :any,
    default: nil,
    doc: "a function from a node to the href it links to, instead of opening its panel"

  attr :class, :any, default: nil
  attr :testid, :string, default: "pipeline-diagram"
  attr :rest, :global

  @doc "A pipeline as connected nodes, over the rail of a person's decisions."
  def pipeline_diagram(%{mode: :micro} = assigns) do
    assigns = assign(assigns, steps: Enum.with_index(assigns.diagram.steps))

    ~H"""
    <span
      class={["inline-flex items-center gap-1", @class]}
      data-testid={@testid}
      aria-label={micro_label(@diagram)}
      {@rest}
    >
      <%= for {step, i} <- @steps do %>
        <span :if={i > 0} class="h-px w-1.5 bg-gray-300 dark:bg-gray-600"></span>
        <span
          class="inline-flex flex-col gap-0.5"
          data-testid={"diagram-step-#{i}"}
          data-parallel={step.parallel?}
        >
          <span
            :for={node <- step.nodes}
            class={["block size-2.5 rounded-full", dot_class(node.state)]}
            title={"#{node.index + 1}. #{node.name}#{node.state && " · " <> state_label(node.state)}"}
            data-testid={"diagram-dot-#{node.index}"}
            data-state={node.state}
          ></span>
        </span>
      <% end %>
    </span>
    """
  end

  def pipeline_diagram(assigns) do
    columns = columns(assigns.diagram)
    total = assigns.diagram.steps |> Enum.flat_map(& &1.nodes) |> length()

    assigns =
      assign(assigns,
        columns: columns,
        total: total,
        template: "grid-template-columns: repeat(#{length(columns)}, max-content)"
      )

    ~H"""
    <div class={["relative overflow-x-auto", @class]} data-testid={@testid} {@rest}>
      <div
        class={[
          "grid min-w-max items-center",
          @mode == :compact && "py-1",
          @mode != :compact && "p-4"
        ]}
        style={@template}
      >
        <.column
          :for={column <- @columns}
          column={column}
          mode={@mode}
          selected={@selected}
          total={@total}
          diagram={@diagram}
          link={@link}
        />
        <%= if @mode != :compact do %>
          <.rail_stub :for={column <- @columns} column={column} edges={@diagram.rail.edges} />
          <.decision_rail cost_cap={@diagram.rail.cost_cap} waiting?={@diagram.waiting?} />
        <% end %>
      </div>
      <p
        :if={@diagram.removed != []}
        class="flex items-center gap-1.5 px-4 pb-4 text-sm text-danger-700 dark:text-danger-300"
        data-testid="diagram-removed"
      >
        <.icon name="hero-minus-circle" class="size-4" /> Saem: {Enum.join(@diagram.removed, ", ")}
      </p>
    </div>
    """
  end

  defp columns(diagram) do
    steps =
      diagram.steps
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, i} ->
        [{:arrow, hd(step.nodes).index}, {:step, step, i}]
      end)

    total = diagram.steps |> Enum.flat_map(& &1.nodes) |> length()
    delivery = if diagram.delivery == :pr, do: [{:delivery}, {:arrow, nil}], else: []

    [{:entry} | steps] ++ [{:arrow, total}] ++ delivery ++ [{:end}]
  end

  attr :column, :any, required: true
  attr :mode, :atom, required: true
  attr :selected, :any, required: true
  attr :total, :integer, required: true
  attr :diagram, :map, required: true
  attr :link, :any, required: true

  defp column(%{column: {:entry}} = assigns) do
    ~H"""
    <.entry_node
      entry={@diagram.entry}
      mode={if @link, do: :compact, else: @mode}
      selected={@selected == :entry}
    />
    """
  end

  defp column(%{column: {:arrow, at}} = assigns) do
    assigns = assign(assigns, at: at)

    ~H"""
    <div class="flex items-center text-gray-300 dark:text-gray-600" aria-hidden={@mode != :edit}>
      <span class={["h-px bg-current", (@mode == :compact && "w-3") || "w-5"]}></span>
      <.button
        :if={@mode == :edit and @at != nil}
        type="button"
        size="xs"
        variant="outline"
        color="gray"
        icon="hero-plus"
        title="Inserir etapa aqui"
        class="!rounded-full !px-1"
        phx-click="insert_stage"
        phx-value-at={@at}
        data-testid={"diagram-insert-#{@at}"}
      >
        <span class="sr-only">Inserir etapa aqui</span>
      </.button>
      <span class={["h-px bg-current", (@mode == :compact && "w-2") || "w-5"]}></span>
      <.icon name="hero-chevron-right" class="-ml-2 size-4" />
    </div>
    """
  end

  defp column(%{column: {:step, step, i}} = assigns) do
    assigns = assign(assigns, step: step, i: i)

    ~H"""
    <div
      :if={not @step.parallel? and @mode != :compact}
      class="flex flex-col items-center self-stretch"
      data-testid={"diagram-step-#{@i}"}
    >
      <span class="flex-1"></span>
      <.stage_node
        :for={node <- @step.nodes}
        node={node}
        mode={@mode}
        selected={@selected == {:stage, node.index}}
        total={@total}
        parallel?={false}
        link={@link}
      />
      <span
        :for={node <- @step.nodes}
        class="w-0 flex-1 border-l-2 border-dashed border-warning-400 dark:border-warning-600"
        data-testid={"diagram-drop-#{node.index}"}
      ></span>
    </div>
    <div
      :if={@step.parallel? or @mode == :compact}
      class="flex items-stretch"
      data-testid={"diagram-step-#{@i}"}
      data-parallel={@step.parallel?}
    >
      <.fork :if={@step.parallel?} id={"diagram-fork-#{@i}"} count={length(@step.nodes)} />
      <div class="grid auto-rows-fr">
        <div :for={node <- @step.nodes} class={[@step.parallel? && "py-1.5"]}>
          <.stage_node
            node={node}
            mode={@mode}
            selected={@selected == {:stage, node.index}}
            total={@total}
            parallel?={@step.parallel?}
            link={@link}
          />
        </div>
      </div>
      <.fork
        :if={@step.parallel?}
        id={"diagram-join-#{@i}"}
        count={length(@step.nodes)}
        join
      />
    </div>
    """
  end

  defp column(%{column: {:delivery}} = assigns) do
    ~H"""
    <div
      class={[
        "flex items-center gap-2 rounded-xl border border-secondary-200 bg-secondary-50 text-secondary-800 dark:border-secondary-900 dark:bg-secondary-950/60 dark:text-secondary-200",
        (@mode == :compact && "px-2 py-1 text-xs") || "px-3 py-2.5 text-sm"
      ]}
      data-testid="diagram-delivery"
    >
      <.icon name="hero-rocket-launch" class="size-5 shrink-0" />
      <span>
        <span class="block font-semibold">Pull request</span>
        <span :if={@mode != :compact} class="block text-xs opacity-80">
          rascunho, pronto ao fim
        </span>
      </span>
    </div>
    """
  end

  defp column(%{column: {:end}} = assigns) do
    ~H"""
    <div
      class={[
        "flex items-center gap-1.5 rounded-full border border-success-200 bg-success-50 font-medium text-success-700 dark:border-success-900 dark:bg-success-950/60 dark:text-success-300",
        (@mode == :compact && "px-2 py-1 text-xs") || "px-3 py-2 text-sm"
      ]}
      data-testid="diagram-end"
    >
      <.icon name="hero-check-circle" class="size-5 shrink-0" /> Concluída
    </div>
    """
  end

  attr :id, :string, required: true
  attr :count, :integer, required: true
  attr :join, :boolean, default: false

  # The curves from a step's start to each of its rows (or back): rows have
  # the same height, so row `i` is centred at `(i + 0.5) / count`.
  defp fork(assigns) do
    assigns =
      assign(assigns,
        paths:
          for i <- 0..(assigns.count - 1) do
            y = Float.round((i + 0.5) * 100 / assigns.count, 2)

            if assigns.join,
              do: "M0 #{y} C12 #{y} 12 50 24 50",
              else: "M0 50 C12 50 12 #{y} 24 #{y}"
          end
      )

    ~H"""
    <svg
      class="w-6 shrink-0 self-stretch text-gray-300 dark:text-gray-600"
      viewBox="0 0 24 100"
      preserveAspectRatio="none"
      fill="none"
      aria-hidden="true"
      data-testid={@id}
    >
      <path
        :for={d <- @paths}
        d={d}
        stroke="currentColor"
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  attr :entry, :map, required: true
  attr :mode, :atom, required: true
  attr :selected, :boolean, required: true

  defp entry_node(%{mode: :compact} = assigns) do
    ~H"""
    <span
      class="flex size-7 items-center justify-center rounded-full bg-primary-600 text-white dark:bg-primary-500"
      data-testid="diagram-entry"
    >
      <.icon name="hero-bolt" class="size-4" />
    </span>
    """
  end

  defp entry_node(assigns) do
    assigns =
      assign(assigns,
        chips:
          Enum.filter(
            [
              assigns.entry.system_prompt? && {"hero-command-line", "instruções de sistema"},
              assigns.entry.mcp_servers != [] &&
                {"hero-server-stack", "MCP: " <> Enum.join(assigns.entry.mcp_servers, ", ")},
              assigns.entry.agents != [] &&
                {"hero-user-group", "agentes: " <> Enum.join(assigns.entry.agents, ", ")}
            ],
            & &1
          )
      )

    ~H"""
    <button
      type="button"
      phx-click="select_node"
      phx-value-node="entry"
      aria-pressed={to_string(@selected)}
      class={[
        "w-52 rounded-xl border bg-white p-3 text-left shadow-sm transition hover:border-primary-400 dark:bg-gray-900",
        (@selected && "border-primary-500 ring-2 ring-primary-500/40") ||
          "border-gray-200 dark:border-gray-700"
      ]}
      data-testid="diagram-entry"
    >
      <span class="flex items-center gap-2">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-primary-600 text-white dark:bg-primary-500">
          <.icon name="hero-bolt" class="size-4" />
        </span>
        <span class="min-w-0">
          <span class="block text-sm font-semibold text-gray-900 dark:text-white">Entrada</span>
          <span class="block truncate text-xs text-gray-500 dark:text-gray-400">
            issue, tarefa ou proposta
          </span>
        </span>
      </span>
      <.stage_chips :if={@chips != []} chips={@chips} class="mt-2" testid="diagram-entry-context" />
    </button>
    """
  end

  attr :node, :map, required: true
  attr :mode, :atom, required: true
  attr :selected, :boolean, required: true
  attr :total, :integer, required: true
  attr :parallel?, :boolean, required: true
  attr :link, :any, default: nil

  defp stage_node(%{mode: :compact} = assigns) do
    ~H"""
    <span
      class="block max-w-36 truncate rounded-lg border border-gray-200 bg-white px-2 py-1 text-xs font-medium text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200"
      data-testid={"diagram-stage-#{@node.index}"}
    >
      {@node.name}
    </span>
    """
  end

  defp stage_node(assigns) do
    ~H"""
    <div
      class={[
        "flex w-60 flex-col rounded-xl border bg-white shadow-sm transition dark:bg-gray-900",
        @parallel? && "h-full",
        node_border(@selected, @node)
      ]}
      data-testid={"diagram-stage-#{@node.index}"}
      data-state={@node.state}
    >
      <.node_target node={@node} selected={@selected} link={@link}>
        <span class="flex items-center gap-2">
          <.stage_state_marker
            state={@node.state || :pending}
            number={@node.index + 1}
            class={[
              "size-6 text-xs",
              !@node.state &&
                "!bg-primary-50 !text-primary-700 dark:!bg-primary-950 dark:!text-primary-300"
            ]}
          />
          <span class="min-w-0 truncate text-sm font-semibold text-gray-900 dark:text-white">
            {@node.name}
          </span>
          <.badge
            :if={@node.diff}
            size="xs"
            variant="soft"
            color={if @node.diff == :added, do: "success", else: "info"}
            label={if @node.diff == :added, do: "nova", else: "alterada"}
            class="ml-auto shrink-0"
            data-testid={"diagram-diff-#{@node.index}"}
          />
        </span>
        <.stage_chips :if={@node.chips != []} chips={@node.chips} class="mt-2" />
        <.stage_chips
          :if={@node.metrics != []}
          chips={@node.metrics}
          class="mt-2"
          testid={"diagram-metrics-#{@node.index}"}
        />
      </.node_target>
      <div class="flex items-center gap-2 border-t border-gray-100 px-3 py-1.5 text-xs text-gray-500 dark:border-gray-800 dark:text-gray-400">
        <span
          class="inline-flex items-center gap-1"
          title="Tentativas: um gate não atendido repete a etapa com o erro"
          data-testid={"diagram-attempts-#{@node.index}"}
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> {@node.attempts}×
        </span>
        <span
          :if={@node.delivers?}
          class="inline-flex items-center gap-1 text-secondary-700 dark:text-secondary-300"
          title="Entrega: a plataforma confere o commit da etapa"
          data-testid={"diagram-delivers-#{@node.index}"}
        >
          <.icon name="hero-check-badge" class="size-3.5" /> commit conferido
        </span>
        <.stage_state_badge
          :if={@node.state}
          state={@node.state}
          class="ml-auto"
          data-testid={"diagram-state-#{@node.index}"}
        />
        <.node_actions
          :if={@mode == :edit}
          index={@node.index}
          total={@total}
          parallel?={@parallel?}
        />
      </div>
    </div>
    """
  end

  defp node_border(true, _node), do: "border-primary-500 ring-2 ring-primary-500/40"

  defp node_border(_selected, %{state: :awaiting}),
    do: "border-warning-400 ring-2 ring-warning-400/40"

  defp node_border(_selected, %{state: :running}), do: "border-info-400 ring-2 ring-info-400/30"
  defp node_border(_selected, %{diff: :added}), do: "border-success-400 dark:border-success-700"
  defp node_border(_selected, %{diff: :changed}), do: "border-info-400 dark:border-info-700"

  defp node_border(_selected, _node),
    do: "border-gray-200 hover:border-primary-400 dark:border-gray-700"

  attr :node, :map, required: true
  attr :selected, :boolean, required: true
  attr :link, :any, required: true
  slot :inner_block, required: true

  # What a click on a node does: open its panel, or follow its link.
  defp node_target(%{link: nil} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_node"
      phx-value-node={@node.index}
      aria-pressed={to_string(@selected)}
      class="flex-1 p-3 text-left"
      data-testid={"diagram-select-#{@node.index}"}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp node_target(assigns) do
    ~H"""
    <a href={@link.(@node)} class="block flex-1 p-3" data-testid={"diagram-select-#{@node.index}"}>
      {render_slot(@inner_block)}
    </a>
    """
  end

  defp dot_class(nil), do: "bg-gray-300 dark:bg-gray-600"
  defp dot_class(:pending), do: "bg-gray-300 dark:bg-gray-600"
  defp dot_class(:passed), do: "bg-success-500"
  defp dot_class(:running), do: "bg-info-500 animate-pulse"
  defp dot_class(state) when state in [:awaiting, :blocked], do: "bg-warning-400"
  defp dot_class(state) when state in [:failed, :canceled], do: "bg-danger-500"

  defp micro_label(diagram) do
    diagram.steps
    |> Enum.flat_map(& &1.nodes)
    |> Enum.map_join(", ", fn node ->
      if node.state, do: "#{node.name}: #{state_label(node.state)}", else: node.name
    end)
  end

  attr :index, :integer, required: true
  attr :total, :integer, required: true
  attr :parallel?, :boolean, required: true

  defp node_actions(assigns) do
    ~H"""
    <span class="ml-auto flex items-center">
      <.action
        icon="hero-arrow-left"
        label="Mover para a esquerda"
        testid={"diagram-left-#{@index}"}
        disabled={@index == 0}
        phx-click="move_stage"
        phx-value-index={@index}
        phx-value-to={@index - 1}
      />
      <.action
        icon="hero-arrow-right"
        label="Mover para a direita"
        testid={"diagram-right-#{@index}"}
        disabled={@index == @total - 1}
        phx-click="move_stage"
        phx-value-index={@index}
        phx-value-to={@index + 1}
      />
      <.action
        :if={@parallel?}
        icon="hero-arrows-pointing-out"
        label="Tirar do grupo em paralelo"
        testid={"diagram-leave-group-#{@index}"}
        phx-click="leave_group"
        phx-value-index={@index}
      />
      <.action
        :if={not @parallel? and @index > 1}
        icon="hero-squares-plus"
        label="Rodar em paralelo com a anterior"
        testid={"diagram-join-group-#{@index}"}
        phx-click="join_group"
        phx-value-index={@index}
      />
      <.action
        icon="hero-trash"
        label="Remover etapa"
        testid={"diagram-remove-#{@index}"}
        color="danger"
        phx-click="remove_stage"
        phx-value-index={@index}
      />
    </span>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :testid, :string, required: true
  attr :color, :string, default: "gray"
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-value-index phx-value-to)

  defp action(assigns) do
    ~H"""
    <.button
      type="button"
      size="xs"
      variant="ghost"
      color={@color}
      icon={@icon}
      title={@label}
      disabled={@disabled}
      class="!px-1"
      data-testid={@testid}
      {@rest}
    >
      <span class="sr-only">{@label}</span>
    </.button>
    """
  end

  attr :column, :any, required: true
  attr :edges, :list, required: true

  # Under a step, the dashed line down to the rail, with what sends each of its
  # stages there.
  defp rail_stub(%{column: {:step, step, _i}} = assigns) do
    indexes = Enum.map(step.nodes, & &1.index)

    assigns =
      assign(assigns,
        edges:
          for index <- indexes do
            edges = Enum.filter(assigns.edges, &(&1.index == index))
            rules = edges |> Enum.filter(&(&1.kind == :rule)) |> Enum.with_index()
            {index, Enum.filter(edges, &(&1.kind == :failure)), rules}
          end
      )

    ~H"""
    <div class="flex flex-col items-center self-stretch pt-2">
      <span class="h-3 border-l-2 border-dashed border-warning-400 dark:border-warning-600"></span>
      <ul class="space-y-1 py-1 text-center">
        <%= for {index, failures, rules} <- @edges do %>
          <li
            :for={edge <- failures}
            class={[
              "text-[11px]",
              (edge.active? &&
                 "rounded-md bg-warning-400 px-1.5 py-0.5 font-semibold text-gray-900") ||
                "text-gray-500 dark:text-gray-400"
            ]}
            data-testid={"diagram-edge-#{index}-failure"}
            data-active={edge.active?}
          >
            {index + 1}: {edge.label}
          </li>
          <li
            :for={{edge, n} <- rules}
            class={[
              "inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 font-mono text-[11px]",
              (edge.active? && "bg-warning-400 font-semibold text-gray-900") ||
                "bg-warning-50 text-warning-800 dark:bg-warning-950/60 dark:text-warning-200"
            ]}
            data-testid={"diagram-edge-#{index}-rule-#{n}"}
            data-active={edge.active?}
          >
            <.icon name="hero-hand-raised" class="size-3" /> {edge.label}
          </li>
        <% end %>
      </ul>
      <span class="min-h-3 flex-1 border-l-2 border-dashed border-warning-400 dark:border-warning-600"></span>
    </div>
    """
  end

  defp rail_stub(assigns), do: ~H"<span></span>"

  attr :cost_cap, :string, default: nil
  attr :waiting?, :boolean, default: false

  defp decision_rail(assigns) do
    ~H"""
    <div
      class={[
        "flex flex-wrap items-center gap-2 rounded-lg border-2 border-dashed px-3 py-2 text-sm text-warning-800 dark:text-warning-200",
        (@waiting? && "border-warning-500 bg-warning-100 dark:bg-warning-900/50") ||
          "border-warning-300 bg-warning-50/60 dark:border-warning-800 dark:bg-warning-950/40"
      ]}
      style="grid-column: 1 / -1"
      data-testid="diagram-rail"
      data-waiting={@waiting?}
    >
      <.icon name="hero-hand-raised" class="size-5 shrink-0" />
      <span class="font-semibold">Pessoa decide</span>
      <span class="text-xs opacity-80">
        a tarefa para e pede uma decisão: repetir, seguir, responder ou cancelar
      </span>
      <.badge
        :if={@cost_cap}
        size="sm"
        variant="outline"
        color="warning"
        class="ml-auto"
        data-testid="diagram-cost-cap"
      >
        <.icon name="hero-banknotes" class="mr-1 size-3.5" /> teto {@cost_cap}
      </.badge>
    </div>
    """
  end

  # ── Stage and pipeline facts ──────────────────────────────────────────────

  attr :chips, :list, required: true, doc: "`PipeMaestroWeb.PipelineDiagram.chips/1`"
  attr :class, :any, default: nil
  attr :testid, :string, default: nil

  @doc "Short facts about a stage (or the entry), as chips."
  def stage_chips(assigns) do
    ~H"""
    <span class={["flex flex-wrap gap-1.5", @class]} data-testid={@testid}>
      <span
        :for={{icon, text} <- @chips}
        class="inline-flex items-center gap-1 rounded-md bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300"
      >
        <.icon name={icon} class="size-3.5" />
        {text}
      </span>
    </span>
    """
  end

  attr :stage, Stage, required: true

  @doc "Everything about a stage, read-only: prompt, gates, rules, output fields."
  def stage_details(assigns) do
    ~H"""
    <div class="space-y-5" data-testid="stage-details">
      <.stage_chips chips={PipelineDiagram.chips(@stage)} />
      <div>
        <.block_heading icon="hero-document-text" title="Prompt" />
        <div
          class="prose prose-sm max-w-none dark:prose-invert"
          data-testid="stage-details-prompt"
        >
          {Markdown.to_html(@stage.prompt)}
        </div>
      </div>
      <div :if={@stage.gates != []} data-testid="stage-details-gates">
        <.block_heading icon="hero-shield-check" title="Gates (comandos depois da etapa)" />
        <ul class="space-y-1 font-mono text-sm text-gray-700 dark:text-gray-200">
          <li :for={gate <- @stage.gates}>
            {if gate["expect"] == "fail", do: "! "}{gate["command"]}
          </li>
        </ul>
      </div>
      <div :if={@stage.rules != []} data-testid="stage-details-rules">
        <.block_heading icon="hero-hand-raised" title="Pede ajuda quando" />
        <ul class="space-y-1 font-mono text-sm text-gray-700 dark:text-gray-200">
          <li :for={rule <- @stage.rules}>{PipelineDiagram.rule_label(rule)}</li>
        </ul>
      </div>
      <div :if={@stage.output_schema} data-testid="stage-details-schema">
        <.block_heading icon="hero-code-bracket-square" title="Campos extras da saída" />
        <pre class="overflow-x-auto rounded-lg bg-gray-50 px-3 py-2 font-mono text-xs text-gray-800 dark:bg-gray-950 dark:text-gray-100">{Json.pretty(@stage.output_schema)}</pre>
      </div>
    </div>
    """
  end

  attr :pipeline, Pipeline, required: true

  @doc "A pipeline's own settings, read-only: delivery, cost cap and context."
  def pipeline_summary(assigns) do
    assigns =
      assign(assigns,
        mcp: names(assigns.pipeline.mcp_config && assigns.pipeline.mcp_config["mcpServers"]),
        agents: names(assigns.pipeline.agents)
      )

    ~H"""
    <div class="space-y-5" data-testid="pipeline-summary">
      <p :if={@pipeline.description} class="text-sm text-gray-600 dark:text-gray-300">
        {@pipeline.description}
      </p>
      <dl class="flex flex-wrap gap-x-4 gap-y-1 text-sm text-gray-600 dark:text-gray-300">
        <div class="flex items-center gap-1" data-testid="pipeline-summary-delivery">
          <dt><.icon name={delivery_icon(@pipeline.delivery)} class="size-4" /></dt>
          <dd>{delivery_label(@pipeline.delivery)}</dd>
        </div>
        <div class="flex items-center gap-1" data-testid="pipeline-summary-cost">
          <dt><.icon name="hero-banknotes" class="size-4" /></dt>
          <dd>{budget_label(@pipeline.max_task_cost_usd)}</dd>
        </div>
      </dl>
      <div :if={@pipeline.system_prompt not in [nil, ""]}>
        <.block_heading icon="hero-command-line" title="Instruções de sistema" />
        <div class="prose prose-sm max-w-none dark:prose-invert">
          {Markdown.to_html(@pipeline.system_prompt)}
        </div>
      </div>
      <div :if={@mcp != []} data-testid="pipeline-summary-mcp">
        <.block_heading icon="hero-server-stack" title="Servidores MCP" />
        <p class="font-mono text-sm text-gray-700 dark:text-gray-200">{Enum.join(@mcp, ", ")}</p>
      </div>
      <div :if={@agents != []} data-testid="pipeline-summary-agents">
        <.block_heading icon="hero-user-group" title="Agentes" />
        <p class="font-mono text-sm text-gray-700 dark:text-gray-200">
          {Enum.join(@agents, ", ")}
        </p>
      </div>
    </div>
    """
  end

  defp names(map) when is_map(map), do: map |> Map.keys() |> Enum.sort()
  defp names(_none), do: []

  # ── The side panel ─────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :open, :boolean, required: true
  attr :testid, :string, default: nil
  slot :inner_block, required: true
  slot :footer

  @doc """
  A panel fixed to the right edge, over the page, that closes with
  `close_panel` (its button or Escape). Closed, it stays in the page, hidden.
  """
  def side_panel(assigns) do
    ~H"""
    <aside
      id={@id}
      class={[
        "pc-slideover__box pc-slideover__box--lg fixed inset-y-0 right-0 z-40 border-l border-gray-200 dark:border-white/10",
        !@open && "hidden"
      ]}
      role="dialog"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@open && "close_panel"}
      phx-key="escape"
      data-testid={@testid}
    >
      <div class="pc-slideover__header">
        <div class="pc-slideover__header__container">
          <div class="pc-slideover__header__titles">
            <div id={"#{@id}-title"} class="pc-slideover__header__text">{@title}</div>
            <div :if={@description} class="pc-slideover__description">{@description}</div>
          </div>
          <button
            type="button"
            phx-click="close_panel"
            class="pc-slideover__header__button"
            data-testid={@testid && "#{@testid}-close"}
          >
            <span class="sr-only">Fechar</span>
            <.icon name="hero-x-mark" class="pc-slideover__header__close-svg" />
          </button>
        </div>
      </div>
      <div class="pc-slideover__content">{render_slot(@inner_block)}</div>
      <div :if={@footer != []} class="pc-slideover__footer">{render_slot(@footer)}</div>
    </aside>
    """
  end
end
