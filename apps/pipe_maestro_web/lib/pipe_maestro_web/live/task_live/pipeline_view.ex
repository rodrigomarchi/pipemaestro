defmodule PipeMaestroWeb.TaskLive.PipelineView do
  @moduledoc """
  The task's page is its pipeline, top to bottom, drawn from the same model as
  every other diagram (`PipeMaestroWeb.PipelineDiagram.build/2` with
  `task_states/1`) and the same vocabulary of states, on the same rail as
  every pipeline (`PipeMaestroWeb.PipelineComponents.rail_item/1`). A step in
  parallel puts its stages side by side.

  Every place on the rail opens a drawer, and the task's content hangs on the
  place it belongs to: the request and where it runs at the entry
  (`?no=entrada`), each stage's attempts at the stage (`?etapa=<key>`), the
  files changed and the merge at the pull request (`?no=entrega`), the cost
  and the files the stages sent at the end (`?no=fim`), and the correction of
  a task that ended in a place after the end (`?no=corrigir`). The decisions
  people took are chained on the rail where they changed the course.

  A stage's node, as wide as the page, carries what is light: its state, the
  summary its last attempt gave (or its error), how long it took and cost,
  its tokens, cache and turns, when it ran and on which runner when not the
  task's. Nothing else a stage produced is read here.

  Over the pipeline, `decision_banner/1` and `runner_alerts/1` say what holds
  the task up; `task_controls/1` goes in the panel of the stage it is on.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.JobComponents,
    only: [format_cost: 1, format_duration: 1, format_percent: 1, short_number: 1]

  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 1]
  import PipeMaestroWeb.QuestionnaireComponents, only: [answer_list: 1]

  import PipeMaestroWeb.PipelineComponents,
    only: [
      delivery_icon: 1,
      delivery_label: 1,
      place_node: 1,
      rail_item: 1,
      stage_state_badge: 1,
      stage_state_marker: 1
    ]

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Tasks
  alias PipeMaestro.Tasks.{StageRun, Task}
  alias PipeMaestroWeb.{Markdown, PipelineDiagram}
  alias PipeMaestroWeb.TaskLive.AttemptComponents

  @doc "The path of the task's page with the stage `key` open, or none when `nil`."
  @spec stage_path(String.t(), Task.t(), String.t() | nil) :: String.t()
  def stage_path(slug, %Task{id: id}, nil), do: ~p"/w/#{slug}/tasks/#{id}"
  def stage_path(slug, %Task{id: id}, key), do: ~p"/w/#{slug}/tasks/#{id}?#{[etapa: key]}"

  # The path of the task's page with one of the places that are not a stage
  # open: `"entrada"`, `"entrega"`, `"fim"` or `"corrigir"`.
  @spec node_path(String.t(), Task.t(), String.t()) :: String.t()
  defp node_path(slug, %Task{id: id}, node), do: ~p"/w/#{slug}/tasks/#{id}?#{[no: node]}"

  # The key of the stage the task waits a decision on, or `nil`.
  @spec awaiting_key(Task.t()) :: String.t() | nil
  defp awaiting_key(%Task{status: :awaiting_decision} = task) do
    case Enum.at(task.stages, task.current_stage) do
      nil -> nil
      stage -> stage.key
    end
  end

  defp awaiting_key(%Task{}), do: nil

  @doc "Whether the pipeline delivers a pull request: the place where it shows."
  @spec delivers_pr?(Task.t()) :: boolean()
  def delivers_pr?(%Task{} = task),
    do: PipelineDiagram.build(PipelineDiagram.for_task(task)).delivery == :pr

  # How many files the attempts of stage `index` sent.
  @spec stage_files(Task.t(), map(), non_neg_integer()) :: non_neg_integer()
  defp stage_files(%Task{stage_runs: runs}, files, index) do
    for(run <- runs, run.index == index, do: length(Map.get(files, run.id, [])))
    |> Enum.sum()
  end

  attr :task, Task, required: true
  attr :slug, :string, required: true
  attr :decisions, :list, required: true, doc: "the decisions taken, oldest first"
  attr :files, :map, required: true, doc: "the files the attempts sent, by stage run id"
  attr :changed_files, :list, required: true
  attr :cost, :any, required: true
  attr :open, :string, default: nil, doc: "the place whose drawer is open"

  @doc """
  The pipeline, vertical: the request at its entry, every stage of the task's
  snapshot and where it stands, the decisions taken between them, the pull
  request, the end and, once the task ended, the correction that may follow.
  Each place opens its drawer.
  """
  @spec overview(map()) :: Phoenix.LiveView.Rendered.t()
  def overview(assigns) do
    task = assigns.task

    diagram =
      PipelineDiagram.build(PipelineDiagram.for_task(task),
        states: PipelineDiagram.task_states(task)
      )

    decisions =
      assigns.decisions
      |> Enum.with_index()
      |> Enum.group_by(fn {decision, _n} ->
        {if(decision.action == :correct, do: :before, else: :after), decision.stage_index}
      end)

    attached = assigns.files |> Map.values() |> Enum.concat() |> length()

    assigns =
      assign(assigns,
        diagram: diagram,
        runs: Enum.group_by(task.stage_runs, & &1.index),
        decided: decisions,
        attached: attached,
        correctable: not Task.active?(task)
      )

    ~H"""
    <ol class="relative" data-testid="task-overview">
      <.rail_item icon="hero-bolt" tone={:primary}>
        <.place_node
          title="Entrada"
          path={node_path(@slug, @task, "entrada")}
          open={@open == "entrada"}
          testid="task-node-entrada"
        >
          Pedido · {(@task.project || %{})["name"] || @task.directory} · {@task.pipeline_name} v{@task.pipeline_version}
        </.place_node>
      </.rail_item>

      <%= for step <- @diagram.steps do %>
        <.decision_item
          :for={{decision, n} <- decided(@decided, :before, step)}
          decision={decision}
          n={n}
          task={@task}
        />
        <.rail_item :if={!step.parallel?} marker={hd(step.nodes)}>
          <.stage_node
            node={hd(step.nodes)}
            runs={Map.get(@runs, hd(step.nodes).index, [])}
            attached={stage_files(@task, @files, hd(step.nodes).index)}
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
              attached={stage_files(@task, @files, node.index)}
              task={@task}
              slug={@slug}
              marker
            />
          </div>
        </.rail_item>
        <.decision_item
          :for={{decision, n} <- decided(@decided, :after, step)}
          decision={decision}
          n={n}
          task={@task}
        />
      <% end %>

      <.rail_item :if={@diagram.delivery == :pr} icon={delivery_icon("pr")} tone={:delivery}>
        <.place_node
          title={delivery_label("pr")}
          path={node_path(@slug, @task, "entrega")}
          open={@open == "entrega"}
          testid="task-node-entrega"
        >
          {count_label(length(@changed_files), "arquivo alterado", "arquivos alterados")}
          <span :if={@task.pr_url}>· PR aberto</span>
        </.place_node>
        <a
          :if={@task.pr_url}
          href={@task.pr_url}
          target="_blank"
          rel="noopener"
          class="mt-1 inline-flex items-center gap-1 text-xs text-primary-600 hover:underline dark:text-primary-400"
          data-testid="task-overview-pr"
        >
          Abrir o pull request <.icon name="hero-arrow-top-right-on-square" class="size-3" />
        </a>
      </.rail_item>

      <.rail_item
        icon={if @diagram.done?, do: "hero-check-circle", else: "hero-flag"}
        tone={if @diagram.done?, do: :done, else: :neutral}
        last={!@correctable}
        dashed
      >
        <.place_node
          title="Fim"
          path={node_path(@slug, @task, "fim")}
          open={@open == "fim"}
          testid="task-overview-end"
        >
          {format_cost(@cost)} · {count_label(@attached, "anexo", "anexos")}
        </.place_node>
      </.rail_item>

      <.rail_item :if={@correctable} icon="hero-plus" tone={:ghost} last>
        <.place_node
          title="Corrigir com um prompt"
          path={node_path(@slug, @task, "corrigir")}
          open={@open == "corrigir"}
          ghost
          testid="task-node-corrigir"
        >
          <span
            :if={no_pr?(@task)}
            class="text-warning-700 dark:text-warning-400"
            data-testid="task-no-pr-warning"
          >
            A tarefa terminou sem PR: peça para abri-lo.
          </span>
          <span :if={!no_pr?(@task)}>Roda como uma nova etapa, na branch desta tarefa.</span>
        </.place_node>
      </.rail_item>
    </ol>
    """
  end

  # The decisions taken before or after a step's stages, with their place in the task.
  defp decided(decided, side, step),
    do: Enum.flat_map(step.nodes, &Map.get(decided, {side, &1.index}, []))

  defp count_label(1, one, _many), do: "1 #{one}"
  defp count_label(n, _one, many), do: "#{n} #{many}"

  attr :decision, :map, required: true
  attr :n, :integer, required: true, doc: "its place among the task's decisions"
  attr :task, Task, required: true

  # A decision a person took, chained on the rail where it changed the course.
  defp decision_item(assigns) do
    assigns =
      assign(assigns,
        details?: assigns.decision.answers != nil or assigns.decision.instructions != nil
      )

    ~H"""
    <.rail_item icon="hero-hand-raised" tone={:decision} small testid={"task-decision-#{@n}"}>
      <p class="text-sm text-gray-900 dark:text-white">
        <span class="font-medium">
          {if @decision.decided_by_user, do: @decision.decided_by_user.name, else: "Alguém"}
        </span>
        decidiu {decision_label(@decision)}
        <span :if={@decision.choice} class="text-gray-600 dark:text-gray-300">
          · escolha: {@decision.choice}
        </span>
      </p>
      <p class="text-xs text-gray-500 dark:text-gray-400">
        {Calendar.strftime(@decision.inserted_at, "%d/%m %H:%M")}
        <span :if={@decision.decided_via} data-testid={"task-decision-via-#{@n}"}>
          · via {@decision.decided_via}
        </span>
      </p>
      <details
        :if={@details?}
        id={"task-decision-details-#{@n}"}
        class="mt-1 text-sm"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary
          class="cursor-pointer text-xs text-gray-500 dark:text-gray-400"
          data-testid={"task-decision-details-#{@n}"}
        >
          {if @decision.answers, do: "Respostas", else: "Instruções"}
        </summary>
        <.answer_list
          :if={@decision.answers}
          answers={Map.merge(@decision.questions || %{}, @decision.answers)}
          class="my-1 space-y-1 text-sm"
          data-testid={"task-decision-answers-#{@n}"}
        />
        <div
          :if={@decision.instructions}
          class="prose prose-sm max-w-none text-gray-600 dark:prose-invert dark:text-gray-300"
        >
          {Markdown.to_html(@decision.instructions)}
        </div>
      </details>
    </.rail_item>
    """
  end

  defp decision_label(%{action: :retry, instructions: i}) when is_binary(i),
    do: "refazer, com instruções"

  defp decision_label(%{action: :retry}), do: "refazer"
  defp decision_label(%{action: :advance}), do: "seguir"
  defp decision_label(%{action: :cancel}), do: "cancelar"
  defp decision_label(%{action: :correct}), do: "corrigir com um prompt"

  attr :node, :map, required: true, doc: "a `PipeMaestroWeb.PipelineDiagram` stage node"
  attr :runs, :list, required: true, doc: "the stage's attempts, light"
  attr :task, Task, required: true
  attr :slug, :string, required: true
  attr :marker, :boolean, default: false, doc: "its own marker, for a stage of a group"
  attr :attached, :integer, default: 0, doc: "how many files its attempts sent"

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
        metrics: metrics(last),
        usage: usage(last && last.job),
        when_ran: when_ran(last),
        runner: other_runner(last, assigns.task),
        summary: last && (last.summary || last.error)
      )

    ~H"""
    <.link
      patch={stage_path(@slug, @task, @stage.key)}
      class={[
        "@container -mt-1 block rounded-xl border bg-white px-4 py-3 transition hover:border-primary-400 hover:shadow-sm dark:bg-gray-900 dark:hover:border-primary-500",
        node_border(@state)
      ]}
      data-testid={"task-stage-#{@stage.key}"}
      data-state={@state}
    >
      <div class="flex items-start gap-3">
        <.stage_state_marker
          :if={@marker}
          state={@state}
          number={@node.index + 1}
          class="size-6 text-xs"
        />
        <div class="flex min-w-0 flex-1 flex-col gap-2 @2xl:flex-row @2xl:gap-6">
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
            <p
              :if={@summary}
              class="mt-1 line-clamp-2 text-sm text-gray-600 dark:text-gray-300"
              title={@summary}
              data-testid={"task-stage-summary-#{@stage.key}"}
            >
              {@summary}
            </p>
          </div>
          <div class="flex shrink-0 flex-col gap-0.5 text-xs text-gray-500 @2xl:w-72 @2xl:items-end @2xl:text-right dark:text-gray-400">
            <p class="flex flex-wrap items-center gap-x-3 @2xl:justify-end">
              <span :if={@attempts > 1} data-testid={"task-stage-attempts-#{@stage.key}"}>
                {@attempts} tentativas
              </span>
              <span :if={@metrics} data-testid={"task-stage-metrics-#{@stage.key}"}>
                {@metrics}
              </span>
              <span
                :if={@attached > 0}
                class="inline-flex items-center gap-0.5"
                title="Arquivos enviados pelo agente"
                data-testid={"task-stage-files-#{@stage.key}"}
              >
                <.icon name="hero-paper-clip" class="size-3" /> {@attached}
              </span>
            </p>
            <p
              :if={@usage}
              class="hidden @md:block"
              data-testid={"task-stage-usage-#{@stage.key}"}
            >
              {@usage}
            </p>
            <p :if={@when_ran} data-testid={"task-stage-when-#{@stage.key}"}>
              {@when_ran}<span :if={@runner}> · em {@runner}</span>
            </p>
          </div>
        </div>
        <.icon name="hero-chevron-right" class="mt-1 size-4 shrink-0 text-gray-400" />
      </div>
    </.link>
    """
  end

  # The tokens of the last attempt, how much came from the cache, and its turns.
  defp usage(%{} = job) do
    tokens = Job.tokens(job)

    if tokens > 0 do
      [
        "#{short_number(tokens)} tokens",
        Job.cache_hit(job) && "#{format_percent(Job.cache_hit(job))} do cache",
        job.num_turns && "#{job.num_turns} #{if job.num_turns == 1, do: "turno", else: "turnos"}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")
    end
  end

  defp usage(_job), do: nil

  # When the last attempt started, or ended.
  defp when_ran(%StageRun{status: :running, job: %{started_at: %DateTime{} = at}}),
    do: "começou #{time_ago(at)}"

  defp when_ran(%StageRun{job: %{finished_at: %DateTime{} = at}}), do: "terminou #{time_ago(at)}"
  defp when_ran(_run), do: nil

  # The runner of the last attempt, when it is not the task's own.
  defp other_runner(%StageRun{job: %{runner: %{id: id, name: name}}}, %Task{
         runner_id: task_runner
       })
       when id != task_runner,
       do: name

  defp other_runner(_run, _task), do: nil

  defp node_border(:running), do: "border-info-400 ring-2 ring-info-400/30 dark:border-info-600"

  defp node_border(:awaiting),
    do: "border-warning-400 ring-2 ring-warning-400/40 dark:border-warning-600"

  defp node_border(_state), do: "border-gray-200 dark:border-gray-800"

  # How long the last attempt took and what it cost, once it ended.
  defp metrics(%StageRun{status: status, job: %{duration_ms: ms} = job})
       when status != :running and is_integer(ms),
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
          <div class="text-sm">{Markdown.inline_html(@task.decision_reason)}</div>
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

  @doc "Over the pipeline: the runner the task waits for, or the one gone offline under it."
  @spec runner_alerts(map()) :: Phoenix.LiveView.Rendered.t()
  def runner_alerts(assigns) do
    ~H"""
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
    """
  end

  # Whether the task can take a message or shows one waiting: its controls show.
  @spec controls?(Task.t()) :: boolean()
  defp controls?(%Task{} = task),
    do: task.status == :running or (Task.active?(task) and task.pending_instructions != nil)

  attr :task, Task, required: true

  @doc """
  In the panel of the stage the task is on: the message waiting for the next
  attempt or stage and, while it runs, a new message, the pause after this
  stage and the interruption.
  """
  @spec task_controls(map()) :: Phoenix.LiveView.Rendered.t()
  def task_controls(assigns) do
    assigns = assign(assigns, instruct: to_form(%{"text" => ""}, as: "instruct"))

    ~H"""
    <div
      :if={controls?(@task)}
      class="rounded-xl border border-gray-200 p-4 dark:border-gray-800"
      data-testid="task-controls"
    >
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
      <.form :if={@task.status == :running} for={@instruct} id="instruct-form" phx-submit="instruct">
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
    </div>
    """
  end

  attr :task, Task, required: true
  attr :online, :any, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :runner_choices, :list, required: true

  @doc "The correction of a task that ended: a prompt run as a new stage."
  @spec correction(map()) :: Phoenix.LiveView.Rendered.t()
  def correction(assigns) do
    ~H"""
    <div class="space-y-4" data-testid="task-correct">
      <p class="text-sm text-gray-500 dark:text-gray-400">
        Roda no worktree e na branch desta tarefa como uma nova etapa, com as verificações,
        os gates e a entrega de sempre.
      </p>
      <.alert :if={no_pr?(@task)} color="warning" with_icon>
        A tarefa terminou sem PR: a entrega não chegou a abri-lo. Peça a correção abaixo.
      </.alert>
      <.form for={@form} id="correct-form" phx-submit="correct">
        <.markdown_editor
          id="task-correct-text"
          field={@form[:prompt]}
          label="O que fazer"
          icon="hero-chat-bubble-bottom-center-text"
          rows={8}
          placeholder="Ex.: resolva o conflito com a main; o PR acusou erro no CI; ajuste o que a revisão pediu."
          testid="task-correct-text"
        />
        <.rerun_runner
          form={@form}
          runners={@runner_choices}
          online={@online}
          testid="task-correct-runner"
        />
        <div class="flex justify-end">
          <.button icon="hero-play" data-testid="task-correct-submit">Rodar a correção</.button>
        </div>
      </.form>
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
