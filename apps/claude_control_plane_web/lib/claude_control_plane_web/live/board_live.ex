defmodule ClaudeControlPlaneWeb.BoardLive do
  @moduledoc """
  The organization's board: headline numbers, tasks by pipeline stage, pending
  human decisions, runners and recent activity.

  The workspace comes from the scope; the pipeline data is still sample data
  from `ClaudeControlPlaneWeb.Demo` until the pipeline domain exists.
  """
  use ClaudeControlPlaneWeb, :live_view

  alias ClaudeControlPlaneWeb.Demo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Board",
       stats: Demo.stats(),
       stages: Demo.stages(),
       tasks_by_stage: Demo.tasks_by_stage(),
       decisions: Demo.decisions(),
       runners: Demo.runners(),
       activity: Demo.activity()
     )}
  end

  @impl true
  def handle_event("decide", %{"id" => id, "option" => option}, socket) do
    {:noreply,
     socket
     |> update(:decisions, fn decisions -> Enum.reject(decisions, &(&1.id == id)) end)
     |> put_flash(:info, "Decisão registrada: #{option}. O pipeline retoma desta etapa.")}
  end

  def handle_event("new_task", _params, socket) do
    {:noreply,
     put_flash(socket, :info, "Novas tarefas chegam pelas issues do GitHub com o gatilho.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:board}
      title="Board"
      pending_decisions={length(@decisions)}
    >
      <:actions>
        <.button
          size="sm"
          icon="hero-plus"
          phx-click="new_task"
          class="hidden sm:inline-flex"
          data-testid="new-task"
        >
          Nova tarefa
        </.button>
      </:actions>

      <div class="space-y-6">
        <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.stat_card :for={stat <- @stats} stat={stat} />
        </div>

        <section aria-labelledby="pipeline-heading">
          <div class="mb-3 flex items-center justify-between">
            <h2 id="pipeline-heading" class="text-sm font-semibold text-gray-900 dark:text-white">
              Pipeline · bug fix
            </h2>
            <span class="text-xs text-gray-500 dark:text-gray-400">
              {@tasks_by_stage |> Map.values() |> List.flatten() |> length()} tarefas
            </span>
          </div>
          <div class="-mx-4 overflow-x-auto px-4 pb-2 sm:-mx-6 sm:px-6 lg:-mx-8 lg:px-8">
            <div class="grid min-w-[66rem] grid-cols-6 gap-4">
              <.stage_column
                :for={stage <- @stages}
                stage={stage}
                tasks={Map.fetch!(@tasks_by_stage, stage.id)}
              />
            </div>
          </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-3">
          <.card class="xl:col-span-2" variant="outline">
            <.card_header
              title="Decisões pendentes"
              description="O pipeline está pausado até alguém decidir."
            >
              <:action>
                <.badge color="warning" variant="soft" label={"#{length(@decisions)} abertas"} />
              </:action>
            </.card_header>
            <.card_content>
              <div :if={@decisions != []} class="divide-y divide-gray-200 dark:divide-gray-800">
                <.decision_row :for={decision <- @decisions} decision={decision} />
              </div>
              <.empty
                :if={@decisions == []}
                title="Nenhuma decisão pendente"
                description="Quando um gate falhar além do limite ou uma etapa exigir aprovação, a pergunta aparece aqui."
              >
                <:icon><.icon name="hero-check-circle" /></:icon>
              </.empty>
            </.card_content>
          </.card>

          <.card variant="outline">
            <.card_header title="Atividade recente" />
            <.card_content>
              <.timeline variant="compact" label="Atividade recente" data-testid="activity">
                <:item
                  :for={event <- @activity}
                  title={event.title}
                  description={event.description}
                  time={event.time}
                  marker="icon"
                  icon={event.icon}
                  color={event.color}
                />
              </.timeline>
            </.card_content>
          </.card>
        </div>

        <.card variant="outline">
          <.card_header
            title="Executores"
            description="Daemons BYO conectados à organização."
          >
            <:action>
              <.button size="xs" variant="outline" color="gray" icon="hero-plus">
                Instalar executor
              </.button>
            </:action>
          </.card_header>
          <.table id="runners" rows={@runners} row_id={&"runner-#{&1.name}"} density="compact">
            <:col :let={runner} label="Executor">
              <div
                class="flex items-center gap-2 font-medium text-gray-900 dark:text-white"
                data-testid={"runner-#{runner.name}"}
              >
                <.icon name="hero-server" class="size-4 text-gray-400" />
                {runner.name}
              </div>
            </:col>
            <:col :let={runner} label="Status">
              <.runner_status status={runner.status} />
            </:col>
            <:col :let={runner} label="Labels">
              <div class="flex flex-wrap gap-1">
                <.badge
                  :for={label <- runner.labels}
                  size="xs"
                  color="gray"
                  variant="outline"
                  label={label}
                />
              </div>
            </:col>
            <:col :let={runner} label="Carga">
              <div class="flex items-center gap-2">
                <.progress
                  size="sm"
                  value={runner.load}
                  max={runner.capacity}
                  color={load_color(runner)}
                  class="w-24"
                />
                <span class="text-xs text-gray-500 dark:text-gray-400">
                  {runner.load}/{runner.capacity}
                </span>
              </div>
            </:col>
            <:col :let={runner} label="Versão">
              <span class="font-mono text-xs">{runner.version}</span>
            </:col>
            <:col :let={runner} label="Visto">
              <span class="text-gray-500 dark:text-gray-400">{runner.last_seen}</span>
            </:col>
          </.table>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :stat, :map, required: true

  defp stat_card(assigns) do
    ~H"""
    <.card variant="outline">
      <.card_content>
        <p class="flex items-center gap-1.5 text-sm text-gray-500 dark:text-gray-400">
          <.icon name={@stat.icon} class="size-4 shrink-0" />
          <span class="truncate">{@stat.label}</span>
        </p>
        <div class="mt-3 flex items-end justify-between gap-4">
          <div>
            <p class="text-2xl font-semibold tracking-tight text-gray-900 dark:text-white">
              {@stat.value}
            </p>
            <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">{@stat.delta}</p>
          </div>
          <.sparkline data={@stat.trend} smooth class="h-10 w-24 shrink-0 text-primary-500" />
        </div>
      </.card_content>
    </.card>
    """
  end

  attr :stage, :map, required: true
  attr :tasks, :list, required: true

  defp stage_column(assigns) do
    ~H"""
    <div
      data-testid={"stage-#{@stage.id}"}
      class="flex min-h-64 flex-col rounded-xl border border-gray-200 bg-gray-100/60 p-3 dark:border-gray-800 dark:bg-gray-900/50"
    >
      <div class="mb-3 flex items-center justify-between px-1">
        <p class="flex items-center gap-1.5 text-sm font-medium text-gray-700 dark:text-gray-200">
          <.icon name={@stage.icon} class="size-4 text-gray-400" />
          {@stage.name}
        </p>
        <.badge size="xs" color="gray" variant="soft" label={Integer.to_string(length(@tasks))} />
      </div>
      <div class="flex flex-1 flex-col gap-3">
        <.task_card :for={task <- @tasks} task={task} />
        <p
          :if={@tasks == []}
          class="flex flex-1 items-center justify-center rounded-lg border border-dashed border-gray-300 p-4 text-center text-xs text-gray-400 dark:border-gray-700"
        >
          Nenhuma tarefa nesta etapa
        </p>
      </div>
    </div>
    """
  end

  attr :task, :map, required: true

  defp task_card(assigns) do
    ~H"""
    <article
      id={"task-#{@task.id}"}
      data-testid={"task-card-#{@task.id}"}
      class={[
        "rounded-lg border bg-white p-3 shadow-xs transition hover:shadow-md dark:bg-gray-900",
        if(@task.status == :waiting_decision,
          do: "border-warning-300 dark:border-warning-500/40",
          else: "border-gray-200 dark:border-gray-800"
        )
      ]}
    >
      <div class="flex flex-wrap items-center gap-1">
        <.badge
          size="xs"
          variant="soft"
          color={kind_color(@task.kind)}
          label={kind_label(@task.kind)}
        />
        <.task_status status={@task.status} />
      </div>
      <p class="mt-2 text-sm font-medium leading-snug text-gray-900 dark:text-white">
        {@task.title}
      </p>
      <p class="mt-1 truncate text-xs text-gray-500 dark:text-gray-400" title={@task.repo}>
        {@task.repo} #{@task.issue}
      </p>
      <div class="mt-3 space-y-1 border-t border-gray-100 pt-2 text-xs text-gray-500 dark:border-gray-800 dark:text-gray-400">
        <p class="flex min-w-0 items-center gap-1" title={task_runner(@task)}>
          <.icon name="hero-server-micro" class="size-3.5 shrink-0" />
          <span class="truncate">{task_runner(@task)}</span>
        </p>
        <p class="flex flex-wrap items-center gap-x-3 gap-y-1 whitespace-nowrap">
          <span :if={@task.elapsed} class="flex items-center gap-1">
            <.icon name="hero-clock-micro" class="size-3.5" />{@task.elapsed}
          </span>
          <span :if={@task.tokens}>{@task.tokens} tok</span>
          <span
            :if={@task.retries > 0}
            class="font-medium text-warning-600 dark:text-warning-400"
            title="Retentativas nesta etapa"
          >
            {@task.retries}× retry
          </span>
        </p>
      </div>
    </article>
    """
  end

  attr :decision, :map, required: true

  defp decision_row(assigns) do
    ~H"""
    <div
      id={"decision-#{@decision.id}"}
      data-testid={"decision-#{@decision.id}"}
      class="flex flex-col gap-3 py-4 first:pt-0 last:pb-0"
    >
      <div class="flex items-start gap-3">
        <span class="inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-warning-100 text-warning-600 dark:bg-warning-500/15 dark:text-warning-400">
          <.icon name="hero-hand-raised" class="size-5" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <p class="text-sm font-semibold text-gray-900 dark:text-white">
              #{@decision.issue} · {@decision.title}
            </p>
            <.badge size="xs" color="gray" variant="outline" label={@decision.stage} />
            <span class="text-xs text-gray-500 dark:text-gray-400">prazo {@decision.due}</span>
          </div>
          <p class="mt-1 text-sm text-gray-600 dark:text-gray-400">{@decision.question}</p>
        </div>
      </div>
      <div class="flex flex-wrap gap-2 pl-12">
        <.button
          :for={{option, index} <- Enum.with_index(@decision.options)}
          size="xs"
          variant={if index == 0, do: "solid", else: "outline"}
          color={option_color(option, index)}
          phx-click="decide"
          phx-value-id={@decision.id}
          data-testid={"decision-#{@decision.id}-option-#{index}"}
          phx-value-option={option}
        >
          {option}
        </.button>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp task_status(assigns) do
    ~H"""
    <.badge
      size="xs"
      variant="soft"
      dot
      color={task_status_color(@status)}
      label={task_status_label(@status)}
    />
    """
  end

  attr :status, :atom, required: true

  defp runner_status(assigns) do
    ~H"""
    <.badge size="sm" variant="soft" dot color={runner_color(@status)} label={runner_label(@status)} />
    """
  end

  defp task_runner(%{runner: runner}) when is_binary(runner), do: runner
  defp task_runner(%{status: :queued}), do: "na fila"
  defp task_runner(%{status: :ready}), do: "workspace liberado"

  defp kind_label(:bug), do: "bug"
  defp kind_label(:feature), do: "feature"
  defp kind_label(:refactor), do: "refactor"
  defp kind_label(:chore), do: "chore"

  defp kind_color(:bug), do: "danger"
  defp kind_color(:feature), do: "primary"
  defp kind_color(:refactor), do: "info"
  defp kind_color(:chore), do: "gray"

  defp task_status_label(:running), do: "Rodando"
  defp task_status_label(:waiting_decision), do: "Aguardando decisão"
  defp task_status_label(:queued), do: "Na fila"
  defp task_status_label(:ready), do: "Pronto p/ revisão"

  defp task_status_color(:running), do: "info"
  defp task_status_color(:waiting_decision), do: "warning"
  defp task_status_color(:queued), do: "gray"
  defp task_status_color(:ready), do: "success"

  defp runner_label(:online), do: "Online"
  defp runner_label(:busy), do: "Ocupado"
  defp runner_label(:offline), do: "Offline"

  defp runner_color(:online), do: "success"
  defp runner_color(:busy), do: "info"
  defp runner_color(:offline), do: "gray"

  defp load_color(%{load: load, capacity: capacity}) when load >= capacity, do: "danger"
  defp load_color(%{load: load, capacity: capacity}) when load * 4 >= capacity * 3, do: "warning"
  defp load_color(_runner), do: "primary"

  defp option_color("Abortar", _index), do: "danger"
  defp option_color(_option, 0), do: "primary"
  defp option_color(_option, _index), do: "gray"
end
