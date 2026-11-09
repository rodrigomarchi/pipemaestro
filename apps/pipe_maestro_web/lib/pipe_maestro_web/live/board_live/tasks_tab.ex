defmodule PipeMaestroWeb.BoardLive.TasksTab do
  @moduledoc """
  The board's "Tarefas" tab: the workspace's tasks in four columns by state
  (running or queued, waiting for a decision, done, failed or canceled),
  filtered by pipeline, runner, project and person. The filters come from
  the URL, so a reload or a shared link keeps them.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.RunnerComponents, only: [time_ago: 2]
  import PipeMaestroWeb.TaskComponents, only: [task_progress: 1, task_tone: 1]

  alias PipeMaestro.{Pipelines, Projects, Tasks, Workspaces}
  alias PipeMaestro.Workspaces.Workspace

  @columns [
    %{
      id: "running",
      name: "Em execução ou na fila",
      icon: "hero-play",
      statuses: [:queued, :running]
    },
    %{
      id: "awaiting",
      name: "Aguardando decisão",
      icon: "hero-hand-raised",
      statuses: [:awaiting_decision]
    },
    %{id: "done", name: "Concluídas", icon: "hero-check-circle", statuses: [:succeeded]},
    %{
      id: "failed",
      name: "Falharam ou canceladas",
      icon: "hero-x-circle",
      statuses: [:failed, :canceled]
    }
  ]

  @doc "The filters the tab takes, by their URL parameter."
  @spec filter_keys() :: [String.t()]
  def filter_keys, do: ~w(pipeline runner_id project_id user_id)

  @doc "What the tab shows of `workspace`, with `filters` (string keys, as in the URL)."
  @spec load(Workspace.t(), map()) :: map()
  def load(%Workspace{} = workspace, filters) do
    %{
      tasks: Tasks.list_tasks(workspace, filters),
      projects: Projects.list_projects(workspace),
      pipelines: Pipelines.list_pipelines(workspace),
      members: Workspaces.list_members(workspace)
    }
  end

  attr :data, :map, required: true
  attr :filters, :map, required: true
  attr :runners, :list, required: true
  attr :slug, :string, required: true
  attr :now, DateTime, required: true

  @doc "The tab."
  @spec tasks(map()) :: Phoenix.LiveView.Rendered.t()
  def tasks(assigns) do
    assigns = assign(assigns, columns: @columns, form: to_form(assigns.filters, as: "filters"))

    ~H"""
    <section aria-labelledby="tasks-heading">
      <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
        <h2 id="tasks-heading" class="text-sm font-semibold text-gray-900 dark:text-white">
          Tarefas
        </h2>
        <.form
          for={@form}
          id="board-filters"
          phx-change="filter"
          class="grid w-full grid-cols-2 gap-2 sm:w-auto sm:grid-cols-4"
        >
          <.icon_field
            field={@form[:pipeline]}
            icon="hero-squares-2x2"
            type="select"
            label="Pipeline"
            options={options(Enum.map(@data.pipelines, & &1.name), "Todos")}
            data-testid="board-filter-pipeline"
          />
          <.icon_field
            field={@form[:runner_id]}
            icon="hero-server-stack"
            type="select"
            label="Runner"
            options={options(Enum.map(@runners, &{&1.name, &1.id}), "Todos")}
            data-testid="board-filter-runner"
          />
          <.icon_field
            field={@form[:project_id]}
            icon="hero-folder-open"
            type="select"
            label="Projeto"
            options={options(Enum.map(@data.projects, &{&1.name, &1.id}), "Todos")}
            data-testid="board-filter-project"
          />
          <.icon_field
            field={@form[:user_id]}
            icon="hero-user"
            type="select"
            label="Pessoa"
            options={options(Enum.map(@data.members, &{&1.name, &1.id}), "Todas")}
            data-testid="board-filter-user"
          />
        </.form>
      </div>
      <div class="-mx-4 overflow-x-auto px-4 pb-2 sm:-mx-6 sm:px-6 lg:-mx-8 lg:px-8">
        <div class="grid min-w-[56rem] grid-cols-4 gap-4">
          <.column
            :for={column <- @columns}
            column={column}
            tasks={Enum.filter(@data.tasks, &(&1.status in column.statuses))}
            slug={@slug}
            now={@now}
          />
        </div>
      </div>
    </section>
    """
  end

  defp options(values, prompt), do: [{prompt, ""} | values]

  attr :column, :map, required: true
  attr :tasks, :list, required: true
  attr :slug, :string, required: true
  attr :now, DateTime, required: true

  defp column(assigns) do
    ~H"""
    <div
      data-testid={"board-column-#{@column.id}"}
      class="flex min-h-64 flex-col rounded-xl border border-gray-200 bg-gray-100/60 p-3 dark:border-gray-800 dark:bg-gray-900/50"
    >
      <div class="mb-3 flex items-center justify-between px-1">
        <p class="flex items-center gap-1.5 text-sm font-medium text-gray-700 dark:text-gray-200">
          <.icon name={@column.icon} class="size-4 text-gray-400" />
          {@column.name}
        </p>
        <.badge size="xs" color="gray" variant="soft" label={Integer.to_string(length(@tasks))} />
      </div>
      <div class="flex flex-1 flex-col gap-3">
        <.record_list :if={@tasks != []}>
          <.record_card
            :for={task <- @tasks}
            testid={"board-task-#{task.id}"}
            navigate={~p"/w/#{@slug}/tasks/#{task.id}"}
            tone={task_tone(task)}
            dense
          >
            <:title>{task.title}</:title>
            <:meta>{task.pipeline_name}</:meta>
            <:meta>
              <.task_progress task={task} testid={"board-task-progress-#{task.id}"} />
            </:meta>
            <:aside>
              <span class="flex min-w-0 items-center gap-1">
                <.icon name="hero-folder-micro" class="size-3.5 shrink-0" />
                <span
                  class="truncate"
                  title={"#{if task.runner, do: task.runner.name, else: "—"}:#{task.directory}"}
                  data-testid="board-card-project"
                >
                  {(task.project || %{})["name"] || task.directory}
                </span>
              </span>
              <span class="shrink-0">{time_ago(task.updated_at, @now)}</span>
            </:aside>
          </.record_card>
        </.record_list>
        <p
          :if={@tasks == []}
          class="flex flex-1 items-center justify-center rounded-lg border border-dashed border-gray-300 p-4 text-center text-xs text-gray-400 dark:border-gray-700"
        >
          Nenhuma tarefa
        </p>
      </div>
    </div>
    """
  end
end
