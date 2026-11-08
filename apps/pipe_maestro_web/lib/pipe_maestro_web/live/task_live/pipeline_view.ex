defmodule PipeMaestroWeb.TaskLive.PipelineView do
  @moduledoc """
  The task's "Etapas" tab at a glance: the pipeline the task runs, top to
  bottom (entry, each step, the delivery of a pull request, the end), drawn
  from the same model as every other diagram
  (`PipeMaestroWeb.PipelineDiagram.build/2` with `task_states/1`) and the same
  vocabulary of states, on the same rail as every pipeline
  (`PipeMaestroWeb.PipelineComponents.rail_item/1`). A step in
  parallel puts its stages side by side.

  Each stage is a node with only light facts: its marker, name and state, how
  many attempts, its group and, once its last attempt ended, how long it took
  and what it cost. A node is a link that opens the stage's panel
  (`?etapa=<key>`); nothing a stage produced is read or rendered here.

  Beside it, `task_sidebar/1` holds what concerns the whole task: the
  runner's alerts, the message, pause and interruption of a running task and
  the correction of one that ended. `decision_banner/1` says the task waits
  for a decision and opens the stage that waits.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.JobComponents, only: [format_cost: 1, format_duration: 1]

  import PipeMaestroWeb.PipelineComponents,
    only: [
      delivery_icon: 1,
      delivery_label: 1,
      rail_item: 1,
      stage_state_badge: 1,
      stage_state_marker: 1
    ]

  alias PipeMaestro.Tasks
  alias PipeMaestro.Tasks.{StageRun, Task}
  alias PipeMaestroWeb.{Markdown, PipelineDiagram}
  alias PipeMaestroWeb.TaskLive.AttemptComponents

  @doc "The path of the task's page with the stage `key` open."
  @spec stage_path(String.t(), Task.t(), String.t() | nil) :: String.t()
  def stage_path(slug, %Task{id: id}, nil), do: ~p"/w/#{slug}/tasks/#{id}?aba=etapas"

  def stage_path(slug, %Task{id: id}, key),
    do: ~p"/w/#{slug}/tasks/#{id}?#{[aba: "etapas", etapa: key]}"

  @doc "The key of the stage the task waits a decision on, or `nil`."
  @spec awaiting_key(Task.t()) :: String.t() | nil
  def awaiting_key(%Task{status: :awaiting_decision} = task) do
    case Enum.at(task.stages, task.current_stage) do
      nil -> nil
      stage -> stage.key
    end
  end

  def awaiting_key(%Task{}), do: nil

  attr :task, Task, required: true
  attr :slug, :string, required: true

  @doc "The pipeline, vertical: every stage of the task's snapshot and where it stands."
  @spec overview(map()) :: Phoenix.LiveView.Rendered.t()
  def overview(assigns) do
    task = assigns.task

    diagram =
      PipelineDiagram.build(PipelineDiagram.for_task(task),
        states: PipelineDiagram.task_states(task)
      )

    runs = Enum.group_by(task.stage_runs, & &1.index)

    assigns = assign(assigns, diagram: diagram, runs: runs)

    ~H"""
    <ol class="relative" data-testid="task-overview">
      <.rail_item icon="hero-bolt" tone={:primary}>
        <p class="text-sm font-medium text-gray-900 dark:text-white">Entrada</p>
        <p class="text-xs text-gray-500 dark:text-gray-400">
          {@task.pipeline_name} · v{@task.pipeline_version}
        </p>
      </.rail_item>

      <%= for step <- @diagram.steps do %>
        <.rail_item :if={!step.parallel?} marker={hd(step.nodes)}>
          <.stage_node
            node={hd(step.nodes)}
            runs={Map.get(@runs, hd(step.nodes).index, [])}
            task={@task}
            slug={@slug}
          />
        </.rail_item>
        <.rail_item :if={step.parallel?} icon="hero-arrows-pointing-out">
          <p
            class="mb-2 text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400"
            data-testid={"task-step-group-#{step.group}"}
          >
            Em paralelo · {step.group}
          </p>
          <div class="grid gap-3 sm:grid-cols-2">
            <.stage_node
              :for={node <- step.nodes}
              node={node}
              runs={Map.get(@runs, node.index, [])}
              task={@task}
              slug={@slug}
              marker
            />
          </div>
        </.rail_item>
      <% end %>

      <.rail_item :if={@diagram.delivery == :pr} icon={delivery_icon("pr")} tone={:delivery}>
        <p class="text-sm font-medium text-gray-900 dark:text-white">{delivery_label("pr")}</p>
        <p :if={@task.pr_url} class="text-xs">
          <a
            href={@task.pr_url}
            target="_blank"
            rel="noopener"
            class="text-primary-600 hover:underline dark:text-primary-400"
            data-testid="task-overview-pr"
          >
            Abrir o pull request <.icon name="hero-arrow-top-right-on-square" class="size-3" />
          </a>
        </p>
      </.rail_item>

      <.rail_item
        icon={if @diagram.done?, do: "hero-check-circle", else: "hero-flag"}
        tone={if @diagram.done?, do: :done, else: :neutral}
        last
      >
        <p class="text-sm font-medium text-gray-900 dark:text-white" data-testid="task-overview-end">
          Fim
        </p>
      </.rail_item>
    </ol>
    """
  end

  attr :node, :map, required: true, doc: "a `PipeMaestroWeb.PipelineDiagram` stage node"
  attr :runs, :list, required: true, doc: "the stage's attempts, light"
  attr :task, Task, required: true
  attr :slug, :string, required: true
  attr :marker, :boolean, default: false, doc: "its own marker, for a stage of a group"

  # A stage, as a link to its panel, with what tells where it stands.
  defp stage_node(assigns) do
    stage = Enum.at(assigns.task.stages, assigns.node.index)
    state = assigns.node.state || :pending
    last = List.last(assigns.runs)

    assigns =
      assign(assigns,
        stage: stage,
        state: state,
        attempts: AttemptComponents.attempts(assigns.runs),
        metrics: metrics(last)
      )

    ~H"""
    <.link
      patch={stage_path(@slug, @task, @stage.key)}
      class={[
        "-mt-1 flex items-start gap-3 rounded-xl border bg-white px-4 py-3 transition hover:border-primary-400 hover:shadow-sm dark:bg-gray-900 dark:hover:border-primary-500",
        node_border(@state)
      ]}
      data-testid={"task-stage-#{@stage.key}"}
      data-state={@state}
    >
      <.stage_state_marker
        :if={@marker}
        state={@state}
        number={@node.index + 1}
        class="size-6 text-xs"
      />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span class={[
            "font-semibold",
            @state == :pending && "text-gray-500 dark:text-gray-400",
            @state != :pending && "text-gray-900 dark:text-white"
          ]}>
            {@stage.name}
          </span>
          <.stage_state_badge state={@state} data-testid={"task-stage-state-#{@stage.key}"} />
          <.badge
            :if={@stage.group not in [nil, ""]}
            size="xs"
            variant="outline"
            color="gray"
            label={"em paralelo · #{@stage.group}"}
            data-testid={"task-stage-group-#{@stage.key}"}
          />
        </div>
        <div class="mt-1 flex flex-wrap items-center gap-x-3 text-xs text-gray-500 dark:text-gray-400">
          <span :if={@attempts > 1} data-testid={"task-stage-attempts-#{@stage.key}"}>
            {@attempts} tentativas
          </span>
          <span :if={@metrics} data-testid={"task-stage-metrics-#{@stage.key}"}>
            {@metrics}
          </span>
        </div>
      </div>
      <.icon name="hero-chevron-right" class="mt-1 size-4 shrink-0 text-gray-400" />
    </.link>
    """
  end

  defp node_border(:running), do: "border-info-400 ring-2 ring-info-400/30 dark:border-info-600"

  defp node_border(:awaiting),
    do: "border-warning-400 ring-2 ring-warning-400/40 dark:border-warning-600"

  defp node_border(_state), do: "border-gray-200 dark:border-gray-800"

  # How long the last attempt took and what it cost, once it ended.
  defp metrics(%StageRun{status: status, job: %{} = job}) when status != :running,
    do: "#{format_duration(job.duration_ms)} · #{format_cost(job.cost_usd)}"

  defp metrics(_run), do: nil

  attr :task, Task, required: true
  attr :slug, :string, required: true

  @doc "Over the pipeline, while the task waits: why, and the way to the stage that waits."
  @spec decision_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def decision_banner(assigns) do
    assigns = assign(assigns, key: awaiting_key(assigns.task))

    ~H"""
    <.alert :if={@key} color="warning" with_icon data-testid="task-decision-banner">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="min-w-0">
          <p class="font-medium">A tarefa aguarda uma decisão.</p>
          <div class="prose prose-sm max-w-none dark:prose-invert">
            {Markdown.inline_html(@task.decision_reason)}
          </div>
        </div>
        <.button
          size="sm"
          color="warning"
          icon="hero-hand-raised"
          link_type="live_patch"
          to={stage_path(@slug, @task, @key)}
          data-testid="task-decision-open"
        >
          Decidir
        </.button>
      </div>
    </.alert>
    """
  end

  attr :task, Task, required: true
  attr :online, :any, required: true
  attr :correct_form, Phoenix.HTML.Form, required: true
  attr :runner_choices, :list, required: true

  @doc """
  What concerns the whole task: the runner's alerts, the message, pause and
  interruption of a running task, and the correction of one that ended.
  """
  @spec task_sidebar(map()) :: Phoenix.LiveView.Rendered.t()
  def task_sidebar(assigns) do
    assigns = assign(assigns, instruct: to_form(%{"text" => ""}, as: "instruct"))

    ~H"""
    <div class="space-y-4" data-testid="task-sidebar">
      <.alert
        :if={Tasks.waiting_for_runner?(@task, @online)}
        color="info"
        with_icon
        data-testid="task-waiting-runner"
      >
        Aguardando o runner {runner_name(@task)} ficar online: a etapa começa assim que ele conectar.
      </.alert>
      <.alert
        :if={Tasks.runner_offline?(@task, @online) and not Tasks.waiting_for_runner?(@task, @online)}
        color="danger"
        with_icon
        data-testid="task-runner-offline"
      >
        <p>
          A tarefa está parada: o runner {runner_name(@task)} está offline.
          Interrompa a etapa para decidir: refazer em outro runner, seguir ou cancelar.
        </p>
        <.button
          size="xs"
          color="danger"
          variant="outline"
          icon="hero-hand-raised"
          phx-click="interrupt"
          class="mt-2"
          data-testid="task-runner-offline-interrupt"
        >
          Interromper a etapa
        </.button>
      </.alert>

      <.card
        :if={@task.status == :running or (Task.active?(@task) and @task.pending_instructions)}
        variant="outline"
      >
        <.card_content>
          <div
            :if={@task.pending_instructions}
            class="mb-3 rounded-lg bg-info-50 px-3 py-2 text-sm text-info-900 dark:bg-info-950/40 dark:text-info-100"
            data-testid="task-pending-instructions"
          >
            <p class="font-medium">Vai na próxima tentativa ou etapa:</p>
            <div class="prose prose-sm max-w-none dark:prose-invert">
              {Markdown.to_html(@task.pending_instructions)}
            </div>
          </div>
          <.form
            :if={@task.status == :running}
            for={@instruct}
            id="instruct-form"
            phx-submit="instruct"
          >
            <.markdown_editor
              id="task-instruct-text"
              field={@instruct[:text]}
              label="Mensagem para a tarefa"
              icon="hero-chat-bubble-bottom-center-text"
              rows={2}
              placeholder="Ex.: não mexa no módulo de pagamentos."
              help_text="Não interrompe a etapa em execução: entra no prompt da próxima tentativa ou etapa."
              testid="task-instruct-text"
            />
            <p
              :if={@task.pause_requested}
              class="mb-2 text-sm text-warning-700 dark:text-warning-400"
              data-testid="task-pause-requested"
            >
              Pausa pedida: a tarefa para quando esta etapa terminar.
            </p>
            <div class="flex flex-wrap items-center justify-end gap-2">
              <.button
                :if={not @task.pause_requested}
                type="button"
                size="sm"
                variant="outline"
                color="gray"
                icon="hero-pause"
                phx-click="request_pause"
                data-testid="task-request-pause"
              >
                Pausar depois desta etapa
              </.button>
              <.button
                type="button"
                size="sm"
                variant="outline"
                color="warning"
                icon="hero-hand-raised"
                phx-click="interrupt"
                data-confirm="Interromper a etapa em execução? A tarefa vai aguardar uma decisão: refazer com instruções, seguir ou cancelar."
                data-testid="task-interrupt"
              >
                Interromper agora
              </.button>
              <.button size="sm" icon="hero-paper-airplane" data-testid="task-instruct">
                Enviar
              </.button>
            </div>
          </.form>
        </.card_content>
      </.card>

      <.card :if={!Task.active?(@task)} variant="outline" data-testid="task-correct">
        <.card_content>
          <.section_heading
            icon="hero-wrench-screwdriver"
            title="Corrigir com um prompt"
            description="Roda no worktree e na branch desta tarefa como uma nova etapa, com as verificações, os gates e a entrega de sempre."
          />
          <.alert
            :if={no_pr?(@task)}
            color="warning"
            with_icon
            class="mb-3"
            data-testid="task-no-pr-warning"
          >
            A tarefa terminou sem PR: a entrega não chegou a abri-lo. Peça a correção abaixo.
          </.alert>
          <.form for={@correct_form} id="correct-form" phx-submit="correct">
            <.markdown_editor
              id="task-correct-text"
              field={@correct_form[:prompt]}
              label="O que fazer"
              icon="hero-chat-bubble-bottom-center-text"
              rows={3}
              placeholder="Ex.: resolva o conflito com a main; o PR acusou erro no CI; ajuste o que a revisão pediu."
              testid="task-correct-text"
            />
            <.rerun_runner
              form={@correct_form}
              runners={@runner_choices}
              online={@online}
              testid="task-correct-runner"
            />
            <div class="flex justify-end">
              <.button icon="hero-play" data-testid="task-correct-submit">Rodar a correção</.button>
            </div>
          </.form>
        </.card_content>
      </.card>
    </div>
    """
  end

  defp runner_name(%Task{runner: %{name: name}}), do: name
  defp runner_name(_task), do: "—"

  @doc "Whether a task that delivers pull requests ended without one."
  @spec no_pr?(Task.t()) :: boolean()
  def no_pr?(%Task{} = task) do
    task.status == :succeeded and task.git and is_nil(task.pr_url) and
      match?(%{"delivery" => "pr"}, task.pipeline_context)
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :runners, :list, required: true
  attr :online, :any, required: true
  attr :testid, :string, required: true

  @doc "Which runner runs a stage again: offered only when there is more than one choice."
  @spec rerun_runner(map()) :: Phoenix.LiveView.Rendered.t()
  def rerun_runner(assigns) do
    ~H"""
    <.icon_field
      :if={length(@runners) > 1}
      field={@form[:runner_id]}
      icon="hero-server-stack"
      type="select"
      label="Runner"
      options={runner_options(@runners, @online)}
      help_text="Outro runner monta o worktree a partir da branch da tarefa no origin."
      data-testid={@testid}
    />
    """
  end

  defp runner_options(runners, online) do
    for runner <- runners do
      {if(MapSet.member?(online, runner.id), do: runner.name, else: "#{runner.name} (offline)"),
       runner.id}
    end
  end
end
