defmodule PipeMaestroWeb.PipelineComponents do
  @moduledoc """
  The pieces a pipeline is shown with, shared by its page
  (`PipeMaestroWeb.PipelineLive.Show`), its editor
  (`PipeMaestroWeb.PipelineLive.Form`) and the list
  (`PipeMaestroWeb.PipelineLive.Index`).

  `pipeline_diagram/1` draws a `PipeMaestroWeb.PipelineDiagram` top to
  bottom, on the same rail (`rail_item/1`) a task's stages are drawn on: the
  entry, each step (a group puts its stages side by side), the delivery and
  the end. Each stage says where it stops for a person, and under them the
  rail of a person's decisions closes the diagram. In `:read` mode a node is
  selected (`select_node`); `:edit` adds the structure's buttons
  (`insert_stage`, `move_stage`, `remove_stage`, `join_group`,
  `leave_group`); `:compact` is an inert preview in a row, as small as it
  gets (a numbered mark per stage, its name in the tooltip), and `:micro` a
  row of dots, one per stage, for where a task is. The diagram's layers (a
  task's states, metrics, a comparison) show on the nodes.

  A stage's state has one vocabulary across the product: `state_label/1`,
  `stage_state_badge/1` and `stage_state_marker/1`.

  `side_panel/1` is the drawer a node opens, the same wherever a pipeline is
  shown, and `drawer_tabs/1` the tabs inside it: what matters most about the
  node first, the rest a tab away. Unlike Petal's `slide_over`, which only opens when mounted, it stays
  in the page while closed (hidden), so a form's inputs inside it keep being
  sent.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.TabComponents, only: [tab_panel: 1]

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

  attr :target, :any, default: nil, doc: "where `select_node` goes (`phx-target`)"

  attr :class, :any, default: nil
  attr :testid, :string, default: "pipeline-diagram"
  attr :rest, :global

  @doc "A pipeline as connected nodes, with where each stage stops for a person."
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

  def pipeline_diagram(%{mode: :compact} = assigns) do
    assigns = assign(assigns, steps: Enum.with_index(assigns.diagram.steps))

    ~H"""
    <div
      class={["overflow-x-auto py-1", @class]}
      data-testid={@testid}
      aria-label={micro_label(@diagram)}
      {@rest}
    >
      <div class="flex min-w-max items-center gap-1">
        <.compact_mark icon="hero-bolt" title="Entrada" tone={:primary} testid="diagram-entry" />
        <%= for {step, i} <- @steps do %>
          <span class="h-px w-2 bg-gray-300 dark:bg-gray-600" aria-hidden="true"></span>
          <span
            class={[
              "flex flex-col gap-0.5",
              step.parallel? && "rounded-full bg-gray-100 p-0.5 dark:bg-gray-800"
            ]}
            data-testid={"diagram-step-#{i}"}
            data-parallel={step.parallel?}
          >
            <span
              :for={node <- step.nodes}
              class="flex size-5 items-center justify-center rounded-full bg-primary-50 text-[10px] font-semibold text-primary-700 dark:bg-primary-950 dark:text-primary-300"
              title={"#{node.index + 1}. #{node.name}"}
              data-testid={"diagram-stage-#{node.index}"}
            >
              {node.index + 1}
            </span>
          </span>
        <% end %>
        <span class="h-px w-2 bg-gray-300 dark:bg-gray-600" aria-hidden="true"></span>
        <%= if @diagram.delivery == :pr do %>
          <.compact_mark
            icon={delivery_icon("pr")}
            title="Pull request"
            tone={:delivery}
            testid="diagram-delivery"
          />
          <span class="h-px w-2 bg-gray-300 dark:bg-gray-600" aria-hidden="true"></span>
        <% end %>
        <.compact_mark icon="hero-flag" title="Fim" tone={:neutral} testid="diagram-end" />
      </div>
    </div>
    """
  end

  def pipeline_diagram(assigns) do
    assigns =
      assign(assigns,
        steps: Enum.with_index(assigns.diagram.steps),
        total: assigns.diagram.steps |> Enum.flat_map(& &1.nodes) |> length()
      )

    ~H"""
    <div class={["p-4 sm:p-6", @class]} data-testid={@testid} data-mode={@mode} {@rest}>
      <ol class="mx-auto max-w-3xl">
        <.rail_item icon="hero-bolt" tone={:primary}>
          <.entry_node entry={@diagram.entry} selected={@selected == :entry} target={@target} />
        </.rail_item>
        <%= for {step, i} <- @steps do %>
          <.insert_slot :if={@mode == :edit} at={hd(step.nodes).index} />
          <.rail_item :if={not step.parallel?} marker={hd(step.nodes)} testid={"diagram-step-#{i}"}>
            <.stage_node
              node={hd(step.nodes)}
              mode={@mode}
              selected={@selected == {:stage, hd(step.nodes).index}}
              total={@total}
              parallel?={false}
              edges={edges(@diagram, hd(step.nodes))}
              target={@target}
            />
          </.rail_item>
          <.rail_item
            :if={step.parallel?}
            icon="hero-arrows-pointing-out"
            testid={"diagram-step-#{i}"}
            data-parallel
          >
            <p
              class="mb-2 text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400"
              data-testid={"diagram-group-#{i}"}
            >
              Em paralelo · {step.group}
            </p>
            <div class="grid gap-3 sm:grid-cols-2">
              <.stage_node
                :for={node <- step.nodes}
                node={node}
                mode={@mode}
                selected={@selected == {:stage, node.index}}
                total={@total}
                parallel?={true}
                edges={edges(@diagram, node)}
                target={@target}
              />
            </div>
          </.rail_item>
        <% end %>
        <.insert_slot :if={@mode == :edit} at={@total} label="Adicionar etapa" />
        <.rail_item :if={@diagram.delivery == :pr} icon={delivery_icon("pr")} tone={:delivery}>
          <div data-testid="diagram-delivery">
            <p class="text-sm font-medium text-gray-900 dark:text-white">Pull request</p>
            <p class="text-xs text-gray-500 dark:text-gray-400">rascunho, pronto ao fim</p>
          </div>
        </.rail_item>
        <.rail_item
          icon={if @diagram.done?, do: "hero-check-circle", else: "hero-flag"}
          tone={if @diagram.done?, do: :done, else: :neutral}
          last
        >
          <p
            class="text-sm font-medium text-gray-900 dark:text-white"
            data-testid="diagram-end"
            data-done={@diagram.done?}
          >
            Fim
          </p>
        </.rail_item>
      </ol>
      <.decision_rail
        cost_cap={@diagram.rail.cost_cap}
        waiting?={@diagram.waiting?}
        class="mx-auto mt-6 max-w-3xl"
      />
      <p
        :if={@diagram.removed != []}
        class="mx-auto mt-4 flex max-w-3xl items-center gap-1.5 text-sm text-danger-700 dark:text-danger-300"
        data-testid="diagram-removed"
      >
        <.icon name="hero-minus-circle" class="size-4" /> Saem: {Enum.join(@diagram.removed, ", ")}
      </p>
    </div>
    """
  end

  defp edges(diagram, node), do: Enum.filter(diagram.rail.edges, &(&1.index == node.index))

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :tone, :atom, required: true
  attr :testid, :string, required: true

  # A place of the compact diagram that is not a stage: an icon, named by its title.
  defp compact_mark(assigns) do
    ~H"""
    <span
      class={["flex size-5 shrink-0 items-center justify-center rounded-full", tone_class(@tone)]}
      title={@title}
      data-testid={@testid}
    >
      <.icon name={@icon} class="size-3" />
    </span>
    """
  end

  attr :icon, :string, default: nil

  attr :marker, :map,
    default: nil,
    doc:
      "a stage node (`PipeMaestroWeb.PipelineDiagram`): its number, or its state, marks the rail"

  attr :tone, :atom,
    default: :neutral,
    values: [:neutral, :primary, :delivery, :done, :decision, :ghost]

  attr :last, :boolean, default: false

  attr :dashed, :boolean,
    default: false,
    doc: "the line to the next place, dashed: it may not come"

  attr :small, :boolean, default: false, doc: "a smaller marker, for what happens between places"
  attr :testid, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  @doc """
  One place on a pipeline's vertical rail, the way every pipeline is drawn
  (`pipeline_diagram/1` and a task's stages): its marker on the line, its
  content beside it.
  """
  @spec rail_item(map()) :: Phoenix.LiveView.Rendered.t()
  def rail_item(assigns) do
    ~H"""
    <li class="relative flex gap-4 pb-5 last:pb-0" data-testid={@testid} {@rest}>
      <div
        :if={!@last}
        class={[
          "absolute left-4 top-9 -bottom-0",
          !@dashed && "w-px bg-gray-200 dark:bg-gray-800",
          @dashed && "border-l border-dashed border-gray-300 dark:border-gray-700"
        ]}
        aria-hidden="true"
      />
      <.stage_state_marker
        :if={@marker}
        state={@marker.state || :pending}
        number={@marker.index + 1}
        class={["size-8 text-sm ring-4 ring-white dark:ring-gray-900", marker_tint(@marker.state)]}
      />
      <span :if={!@marker} class="flex w-8 shrink-0 justify-center">
        <span class={[
          "relative z-10 flex shrink-0 items-center justify-center rounded-full ring-4 ring-white dark:ring-gray-900",
          if(@small, do: "mt-1 size-6", else: "size-8"),
          tone_class(@tone)
        ]}>
          <.icon name={@icon} class={if @small, do: "size-3.5", else: "size-4"} />
        </span>
      </span>
      <div class="min-w-0 flex-1 pt-1">{render_slot(@inner_block)}</div>
    </li>
    """
  end

  attr :title, :string, required: true
  attr :path, :string, required: true, doc: "the page with this place's drawer open (a patch)"
  attr :open, :boolean, default: false, doc: "its drawer is open"
  attr :ghost, :boolean, default: false, doc: "dashed: something that may still be done"

  attr :tone, :atom,
    default: nil,
    values: [nil, :running, :awaiting, :ready],
    doc: "a ring that calls attention: it runs, waits on a person, or is ready to review"

  attr :truncate, :boolean, default: true, doc: "its facts on one line"
  attr :testid, :string, required: true
  slot :badge, doc: "beside the title: its state"
  slot :inner_block, required: true, doc: "its light facts"

  @doc """
  A place on a vertical rail (`rail_item/1`) as a link to its drawer, with
  its light facts: every flow drawn as a pipeline (a task, a run, a proposal)
  opens what belongs to a place from here.
  """
  @spec place_node(map()) :: Phoenix.LiveView.Rendered.t()
  def place_node(assigns) do
    ~H"""
    <.link
      patch={@path}
      class={[
        "-mt-1 flex items-center gap-3 rounded-xl border px-4 py-2.5 transition hover:border-primary-400 hover:shadow-sm dark:hover:border-primary-500",
        @ghost && "border-dashed border-gray-300 dark:border-gray-700",
        !@ghost && "bg-white dark:bg-gray-900",
        !@ghost && !@open && place_border(@tone),
        @open && "border-primary-500 ring-2 ring-primary-500/30"
      ]}
      data-testid={@testid}
    >
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <p class="text-sm font-medium text-gray-900 dark:text-white">{@title}</p>
          {render_slot(@badge)}
        </div>
        <div class={["mt-0.5 text-xs text-gray-500 dark:text-gray-400", @truncate && "truncate"]}>
          {render_slot(@inner_block)}
        </div>
      </div>
      <.icon name="hero-chevron-right" class="size-4 shrink-0 text-gray-400" />
    </.link>
    """
  end

  defp place_border(:running), do: "border-info-400 ring-2 ring-info-400/30 dark:border-info-600"

  defp place_border(:awaiting),
    do: "border-warning-400 ring-2 ring-warning-400/40 dark:border-warning-600"

  defp place_border(:ready),
    do: "border-success-400 ring-2 ring-success-400/30 dark:border-success-600"

  defp place_border(nil), do: "border-gray-200 dark:border-gray-800"

  # A pipeline's stage, which no task has run, is numbered in the brand's tint.
  defp marker_tint(nil),
    do: "!bg-primary-50 !text-primary-700 dark:!bg-primary-950 dark:!text-primary-300"

  defp marker_tint(_state), do: nil

  defp tone_class(:primary), do: "bg-primary-600 text-white dark:bg-primary-500"

  defp tone_class(:delivery),
    do: "bg-secondary-100 text-secondary-700 dark:bg-secondary-900/60 dark:text-secondary-300"

  defp tone_class(:done),
    do: "bg-success-100 text-success-700 dark:bg-success-900/60 dark:text-success-300"

  defp tone_class(:neutral), do: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"

  defp tone_class(:decision),
    do: "bg-warning-100 text-warning-700 dark:bg-warning-900/60 dark:text-warning-300"

  defp tone_class(:ghost),
    do:
      "border border-dashed border-gray-300 bg-white text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400"

  attr :at, :integer, required: true
  attr :label, :string, default: nil

  # Where the editor inserts a stage: a `+` on the line between two steps, or
  # a labelled button after the last one.
  defp insert_slot(assigns) do
    ~H"""
    <li class="relative -mt-2 flex items-center gap-4 pb-3">
      <div class="absolute left-4 inset-y-0 w-px bg-gray-200 dark:bg-gray-800" aria-hidden="true" />
      <span class="relative z-10 flex w-8 shrink-0 justify-center">
        <.button
          :if={!@label}
          type="button"
          size="xs"
          variant="outline"
          color="gray"
          icon="hero-plus"
          title="Inserir etapa aqui"
          class="!rounded-full !bg-white !px-1 dark:!bg-gray-900"
          phx-click="insert_stage"
          phx-value-at={@at}
          data-testid={"diagram-insert-#{@at}"}
        >
          <span class="sr-only">Inserir etapa aqui</span>
        </.button>
        <span
          :if={@label}
          class="size-2.5 rounded-full bg-gray-300 ring-4 ring-white dark:bg-gray-600 dark:ring-gray-900"
        ></span>
      </span>
      <.button
        :if={@label}
        type="button"
        size="sm"
        variant="outline"
        icon="hero-plus"
        phx-click="insert_stage"
        phx-value-at={@at}
        data-testid={"diagram-insert-#{@at}"}
      >
        {@label}
      </.button>
    </li>
    """
  end

  attr :entry, :map, required: true
  attr :selected, :boolean, required: true
  attr :target, :any, default: nil

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
      phx-target={@target}
      phx-value-node="entry"
      aria-pressed={to_string(@selected)}
      class={[
        "-mt-1 block w-full rounded-xl border bg-white p-3 text-left shadow-sm transition hover:border-primary-400 dark:bg-gray-900",
        (@selected && "border-primary-500 ring-2 ring-primary-500/40") ||
          "border-gray-200 dark:border-gray-700"
      ]}
      data-testid="diagram-entry"
    >
      <span class="flex items-center gap-2">
        <span class="text-sm font-semibold text-gray-900 dark:text-white">Entrada</span>
        <span class="text-xs text-gray-500 dark:text-gray-400">issue, tarefa ou proposta</span>
        <.icon name="hero-chevron-right" class="ml-auto size-4 shrink-0 text-gray-400" />
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
  attr :edges, :list, required: true, doc: "where the stage stops for a person"
  attr :target, :any, default: nil

  defp stage_node(assigns) do
    assigns =
      assign(assigns,
        failures: Enum.filter(assigns.edges, &(&1.kind == :failure)),
        rules: assigns.edges |> Enum.filter(&(&1.kind == :rule)) |> Enum.with_index()
      )

    ~H"""
    <div
      class={[
        "flex flex-col rounded-xl border bg-white shadow-sm transition dark:bg-gray-900",
        (@parallel? && "h-full") || "-mt-1",
        node_border(@selected, @node)
      ]}
      data-testid={"diagram-stage-#{@node.index}"}
      data-state={@node.state}
    >
      <button
        type="button"
        phx-click="select_node"
        phx-target={@target}
        phx-value-node={@node.index}
        aria-pressed={to_string(@selected)}
        class="flex-1 p-3 text-left"
        data-testid={"diagram-select-#{@node.index}"}
      >
        <span class="flex items-center gap-2">
          <.stage_state_marker
            :if={@parallel?}
            state={@node.state || :pending}
            number={@node.index + 1}
            class={["size-6 text-xs", marker_tint(@node.state)]}
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
            class="shrink-0"
            data-testid={"diagram-diff-#{@node.index}"}
          />
          <.icon name="hero-chevron-right" class="ml-auto size-4 shrink-0 text-gray-400" />
        </span>
        <.stage_chips :if={@node.chips != []} chips={@node.chips} class="mt-2" />
        <.stage_chips
          :if={@node.metrics != []}
          chips={@node.metrics}
          class="mt-2"
          testid={"diagram-metrics-#{@node.index}"}
        />
      </button>
      <div
        :if={@rules != []}
        class="flex flex-wrap items-center gap-1.5 border-t border-dashed border-warning-300 px-3 py-1.5 dark:border-warning-800"
        data-testid={"diagram-rules-#{@node.index}"}
      >
        <span class="inline-flex items-center gap-1 text-[11px] font-medium text-warning-700 dark:text-warning-300">
          <.icon name="hero-hand-raised" class="size-3.5" /> Pede ajuda quando
        </span>
        <span
          :for={{edge, n} <- @rules}
          class={[
            "rounded-md px-1.5 py-0.5 font-mono text-[11px]",
            (edge.active? && "bg-warning-400 font-semibold text-gray-900") ||
              "bg-warning-50 text-warning-800 dark:bg-warning-950/60 dark:text-warning-200"
          ]}
          data-testid={"diagram-edge-#{@node.index}-rule-#{n}"}
          data-active={edge.active?}
        >
          {edge.label}
        </span>
      </div>
      <div class="flex items-center gap-2 border-t border-gray-100 px-3 py-1.5 text-xs text-gray-500 dark:border-gray-800 dark:text-gray-400">
        <span
          class="inline-flex items-center gap-1"
          title="Tentativas: um gate não atendido repete a etapa com o erro"
          data-testid={"diagram-attempts-#{@node.index}"}
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> {@node.attempts}×
        </span>
        <span
          :for={edge <- @failures}
          class={[
            "inline-flex items-center gap-1 rounded-md",
            edge.active? && "bg-warning-400 px-1.5 py-0.5 font-semibold text-gray-900"
          ]}
          title="Uma pessoa decide quando a etapa esgota as tentativas ou bloqueia"
          data-testid={"diagram-edge-#{@node.index}-failure"}
          data-active={edge.active?}
        >
          <.icon name="hero-hand-raised" class="size-3.5" /> {edge.label}
        </span>
        <span
          :if={@node.delivers?}
          class="inline-flex items-center gap-1 text-secondary-700 dark:text-secondary-300"
          title="Entrega: a plataforma confere o commit da etapa"
          data-testid={"diagram-delivers-#{@node.index}"}
        >
          <.icon name="hero-check-badge" class="size-3.5" /> commit
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
        icon="hero-arrow-up"
        label="Subir"
        testid={"diagram-up-#{@index}"}
        disabled={@index == 0}
        phx-click="move_stage"
        phx-value-index={@index}
        phx-value-to={@index - 1}
      />
      <.action
        icon="hero-arrow-down"
        label="Descer"
        testid={"diagram-down-#{@index}"}
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

  attr :cost_cap, :string, default: nil
  attr :waiting?, :boolean, default: false
  attr :class, :any, default: nil

  defp decision_rail(assigns) do
    ~H"""
    <div
      class={[
        "flex flex-wrap items-center gap-2 rounded-lg border-2 border-dashed px-3 py-2 text-sm text-warning-800 dark:text-warning-200",
        (@waiting? && "border-warning-500 bg-warning-100 dark:bg-warning-900/50") ||
          "border-warning-300 bg-warning-50/60 dark:border-warning-800 dark:bg-warning-950/40",
        @class
      ]}
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

  attr :pipelines, :list, required: true
  attr :id, :any, required: true, doc: "the chosen pipeline's id, from a select"
  attr :testid, :string, required: true

  @doc "The pipeline chosen in a select, as a small diagram; nothing before one is chosen."
  def pipeline_preview(assigns) do
    assigns = assign(assigns, pipeline: Enum.find(assigns.pipelines, &(&1.id == assigns.id)))

    ~H"""
    <div
      :if={@pipeline}
      class="-mt-2 mb-4 rounded-lg border border-gray-200 bg-gray-50 px-3 dark:border-gray-700 dark:bg-gray-950"
    >
      <.pipeline_diagram
        diagram={PipelineDiagram.build(@pipeline)}
        mode={:compact}
        testid={@testid}
      />
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

  # ── A node's tabs ─────────────────────────────────────────────────────────

  @typedoc "A tab of a node's drawer: its id, label and icon."
  @type drawer_tab :: {String.t(), String.t(), String.t()}

  attr :tabs, :list, required: true, doc: "a list of `t:drawer_tab/0`"
  attr :active, :string, required: true
  attr :testid, :string, required: true, doc: "prefix of the test ids (`<testid>-tab-<id>`)"
  attr :errors, :list, default: [], doc: "the ids of the tabs whose fields have an error"
  attr :target, :any, default: nil, doc: "where `select_tab` goes (`phx-target`)"

  attr :class, :any,
    default: "sticky -top-6 z-10 -mx-6 -mt-6 mb-6 bg-white px-6 dark:bg-gray-900",
    doc: "where the row sits: by default stuck to the top of the drawer as it scrolls"

  @doc """
  The row of tabs at the top of a node's drawer, the same in every drawer: the
  first tab is what matters most about the node (a stage's prompt and model),
  the others what is looked at less. A click sends `select_tab` with the tab's
  id. A tab whose fields have an error is marked, so an error in a tab not
  chosen still shows. One tab alone is not drawn.
  """
  def drawer_tabs(assigns) do
    ~H"""
    <.tabs
      :if={length(@tabs) > 1}
      variant="underline"
      class={["overflow-x-auto", @class]}
      data-testid={"#{@testid}-tabs"}
    >
      <.tab
        :for={{id, label, icon} <- @tabs}
        link_type="button"
        variant="underline"
        is_active={@active == id}
        phx-click="select_tab"
        phx-value-tab={id}
        phx-target={@target}
        class="whitespace-nowrap"
        data-testid={"#{@testid}-tab-#{id}"}
      >
        <.icon name={icon} class="mr-1.5 size-4" /> {label}
        <span
          :if={id in @errors}
          class="ml-1.5 size-2 rounded-full bg-danger-500"
          title="Tem um erro"
          data-testid={"#{@testid}-tab-error-#{id}"}
        ></span>
      </.tab>
    </.tabs>
    """
  end

  @doc "The tab of `tabs` named `tab`, else the first: what a drawer shows."
  @spec chosen_tab([drawer_tab()], String.t() | nil) :: String.t()
  def chosen_tab([{first, _, _} | _] = tabs, tab),
    do: if(Enum.any?(tabs, &(elem(&1, 0) == tab)), do: tab, else: first)

  # The tabs of a stage's details: its prompt, and how it is checked and its output when it has them.
  @spec stage_detail_tabs(Stage.t()) :: [drawer_tab()]
  defp stage_detail_tabs(%Stage{} = stage) do
    [
      {"prompt", "Prompt", "hero-pencil-square"},
      (stage.gates != [] or stage.rules != []) &&
        {"verificacao", "Verificação", "hero-shield-check"},
      stage.output_schema && {"avancado", "Avançado", "hero-adjustments-horizontal"}
    ]
    |> Enum.filter(& &1)
  end

  attr :stage, Stage, required: true

  attr :tab, :string,
    default: nil,
    doc: "the tab shown (`stage_detail_tabs/1`); the first when nil"

  attr :target, :any, default: nil, doc: "where `select_tab` goes (`phx-target`)"
  attr :testid, :string, default: "stage-details"

  @doc """
  Everything about a stage, read-only, in tabs: its model and the like over its
  prompt first; its gates and rules; its output fields.
  """
  def stage_details(assigns) do
    tabs = stage_detail_tabs(assigns.stage)
    assigns = assign(assigns, tabs: tabs, tab: chosen_tab(tabs, assigns.tab))

    ~H"""
    <div data-testid="stage-details">
      <.drawer_tabs tabs={@tabs} active={@tab} target={@target} testid={@testid} />
      <.tab_panel id="prompt" active={@tab} testid={@testid} class="space-y-4">
        <.stage_chips chips={PipelineDiagram.chips(@stage)} />
        <div
          class="prose prose-sm max-w-none dark:prose-invert"
          data-testid="stage-details-prompt"
        >
          {Markdown.to_html(@stage.prompt)}
        </div>
      </.tab_panel>
      <.tab_panel id="verificacao" active={@tab} testid={@testid} class="space-y-5">
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
      </.tab_panel>
      <.tab_panel id="avancado" active={@tab} testid={@testid}>
        <div :if={@stage.output_schema} data-testid="stage-details-schema">
          <.block_heading icon="hero-code-bracket-square" title="Campos extras da saída" />
          <pre class="overflow-x-auto rounded-lg bg-gray-50 px-3 py-2 font-mono text-xs text-gray-800 dark:bg-gray-950 dark:text-gray-100">{Json.pretty(@stage.output_schema)}</pre>
        </div>
      </.tab_panel>
    </div>
    """
  end

  defp merge_method_label("merge"), do: "merge commit"
  defp merge_method_label(method), do: method

  # The tabs of a pipeline's summary: the general one, and its MCP servers and agents when it has them.
  @spec pipeline_summary_tabs(Pipeline.t()) :: [drawer_tab()]
  defp pipeline_summary_tabs(%Pipeline{} = pipeline) do
    advanced? = mcp_names(pipeline) != [] or names(pipeline.agents) != []

    [
      {"geral", "Geral", "hero-identification"},
      advanced? && {"avancado", "Avançado", "hero-puzzle-piece"}
    ]
    |> Enum.filter(& &1)
  end

  attr :pipeline, Pipeline, required: true

  attr :tab, :string,
    default: nil,
    doc: "the tab shown (`pipeline_summary_tabs/1`); the first when nil"

  attr :target, :any, default: nil, doc: "where `select_tab` goes (`phx-target`)"
  attr :testid, :string, default: "pipeline-summary"

  @doc """
  A pipeline's own settings, read-only, in tabs: its description, delivery,
  cost cap, the merge of the pull request and system instructions first; its
  MCP servers and agents.
  """
  def pipeline_summary(assigns) do
    tabs = pipeline_summary_tabs(assigns.pipeline)

    assigns =
      assign(assigns,
        tabs: tabs,
        tab: chosen_tab(tabs, assigns.tab),
        mcp: mcp_names(assigns.pipeline),
        agents: names(assigns.pipeline.agents)
      )

    ~H"""
    <div data-testid="pipeline-summary">
      <.drawer_tabs tabs={@tabs} active={@tab} target={@target} testid={@testid} />
      <.tab_panel id="geral" active={@tab} testid={@testid} class="space-y-5">
        <div :if={@pipeline.description} class="text-sm text-gray-600 dark:text-gray-300">
          {Markdown.inline_html(@pipeline.description)}
        </div>
        <dl class="flex flex-wrap gap-x-4 gap-y-1 text-sm text-gray-600 dark:text-gray-300">
          <div class="flex items-center gap-1" data-testid="pipeline-summary-delivery">
            <dt><.icon name={delivery_icon(@pipeline.delivery)} class="size-4" /></dt>
            <dd>{delivery_label(@pipeline.delivery)}</dd>
          </div>
          <div class="flex items-center gap-1" data-testid="pipeline-summary-cost">
            <dt><.icon name="hero-banknotes" class="size-4" /></dt>
            <dd>{budget_label(@pipeline.max_task_cost_usd)}</dd>
          </div>
          <div
            :if={@pipeline.auto_merge}
            class="flex items-center gap-1"
            data-testid="pipeline-summary-auto-merge"
          >
            <dt><.icon name="hero-arrows-pointing-in" class="size-4" /></dt>
            <dd>
              Merge sozinha ({merge_method_label(@pipeline.merge_method)}, até {@pipeline.max_merge_fixes} correções)
            </dd>
          </div>
        </dl>
        <div :if={@pipeline.system_prompt not in [nil, ""]}>
          <.block_heading icon="hero-command-line" title="Instruções de sistema" />
          <div class="prose prose-sm max-w-none dark:prose-invert">
            {Markdown.to_html(@pipeline.system_prompt)}
          </div>
        </div>
      </.tab_panel>
      <.tab_panel id="avancado" active={@tab} testid={@testid} class="space-y-5">
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
      </.tab_panel>
    </div>
    """
  end

  defp mcp_names(pipeline), do: names(pipeline.mcp_config && pipeline.mcp_config["mcpServers"])

  defp names(map) when is_map(map), do: map |> Map.keys() |> Enum.sort()
  defp names(_none), do: []

  # ── The side panel ─────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :open, :boolean, required: true
  attr :testid, :string, default: nil
  attr :target, :any, default: nil, doc: "where `close_panel` goes (`phx-target`)"

  attr :escape, :boolean,
    default: true,
    doc: "Escape closes it; off when it holds a drawer of its own, which Escape closes alone"

  slot :inner_block, required: true
  slot :footer

  @doc """
  A drawer fixed to the right edge, 90% of a wide screen and all of a
  phone's, over a backdrop. It closes with `close_panel`: its button, Escape
  (unless `escape` is off) or a click on the backdrop. Closed, it stays in
  the page, hidden.
  """
  def side_panel(assigns) do
    ~H"""
    <div
      class={["fixed inset-0 z-30 bg-gray-900/50 dark:bg-black/60", !@open && "hidden"]}
      phx-click="close_panel"
      phx-target={@target}
      aria-hidden="true"
      data-testid={@testid && "#{@testid}-backdrop"}
    >
    </div>
    <aside
      id={@id}
      class={[
        "fixed inset-y-0 right-0 z-40 flex w-full flex-col border-l border-gray-200 bg-white shadow-xl lg:w-[90vw] dark:border-white/10 dark:bg-gray-900",
        !@open && "hidden"
      ]}
      role="dialog"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@open && @escape && "close_panel"}
      phx-target={@target}
      phx-key="escape"
      data-testid={@testid}
    >
      <div class="pc-slideover__header">
        <div class="pc-slideover__header__container">
          <div class="pc-slideover__header__titles">
            <div
              id={"#{@id}-title"}
              class="pc-slideover__header__text"
              data-testid={@testid && "#{@testid}-title"}
            >
              {@title}
            </div>
            <div :if={@description} class="pc-slideover__description">{@description}</div>
          </div>
          <button
            type="button"
            phx-click="close_panel"
            phx-target={@target}
            class="pc-slideover__header__button"
            data-testid={@testid && "#{@testid}-close"}
          >
            <span class="sr-only">Fechar</span>
            <.icon name="hero-x-mark" class="pc-slideover__header__close-svg" />
          </button>
        </div>
      </div>
      <div class="pc-slideover__content min-h-0 flex-1 overflow-y-auto">
        {render_slot(@inner_block)}
      </div>
      <div :if={@footer != []} class="pc-slideover__footer">{render_slot(@footer)}</div>
    </aside>
    """
  end
end
