defmodule PipeMaestroWeb.ProjectLive.Index do
  @moduledoc """
  The workspace's projects: for each, its runner and whether it is online,
  whether it can take work (`PipeMaestro.Projects.health/2`), its latest
  tasks, shortcuts to start work in it, and the commands that set up a
  task's worktree, test and lint it.
  """
  use PipeMaestroWeb, :live_view

  alias Phoenix.Socket.Broadcast
  alias PipeMaestro.Audit
  alias PipeMaestro.Projects
  alias PipeMaestroWeb.RunnerStatus

  @recent_tasks 3

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: RunnerStatus.subscribe(socket.assigns.current_scope.workspace.id)
    {:ok, socket |> assign(page_title: "Projetos") |> load_projects()}
  end

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load_projects(socket)}

  def handle_info(:runners_changed, socket), do: {:noreply, load_projects(socket)}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    if can?(socket.assigns.current_scope, :manage_projects),
      do: delete(socket, id),
      else: {:noreply, put_flash(socket, :error, "Só admins do workspace mudam os projetos.")}
  end

  defp delete(socket, id) do
    project = Projects.get_project!(socket.assigns.current_scope.workspace, id)
    {:ok, _} = Projects.delete_project(project)
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    Audit.record(workspace, user, "project.deleted", project)

    {:noreply, socket |> put_flash(:info, "Projeto #{project.name} removido.") |> load_projects()}
  end

  defp load_projects(socket) do
    workspace = socket.assigns.current_scope.workspace
    online = RunnerStatus.online_ids(workspace.id)

    projects =
      for project <- Projects.list_projects(workspace) do
        %{
          project: project,
          health: Projects.health(project, online),
          tasks: Projects.recent_tasks(project, @recent_tasks)
        }
      end

    assign(socket, projects: projects)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:projects}
      title="Projetos"
    >
      <:actions>
        <.button
          :if={can?(@current_scope, :manage_projects)}
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/projects/new"}
          size="sm"
          icon="hero-plus"
          data-testid="new-project"
        >
          Novo projeto
        </.button>
      </:actions>

      <.card :if={@projects == []} variant="outline">
        <.card_content>
          <.empty
            data-testid="no-projects"
            title="Nenhum projeto ainda"
            description="Um projeto é um diretório de código de um runner: é onde as tarefas rodam. Ele diz como preparar o worktree (setup e o que copiar), como testar e o que os agentes devem saber."
          >
            <:icon><.icon name="hero-folder" /></:icon>
          </.empty>
        </.card_content>
      </.card>

      <div class="space-y-4">
        <.card
          :for={%{project: project, health: health, tasks: tasks} <- @projects}
          variant="outline"
          data-testid={"project-#{project.directory}"}
        >
          <.card_content>
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="font-semibold text-gray-900 dark:text-white">{project.name}</p>
                <p class="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                  <span class="inline-flex items-center gap-1">
                    <.icon name="hero-server" class="size-3.5" />
                    <span data-testid={"project-runner-#{project.directory}"}>
                      {if project.runner, do: project.runner.name, else: "sem runner"}
                    </span>
                  </span>
                  <span class="font-mono">{project.directory}</span>
                  <.badge
                    :if={project.runner}
                    size="sm"
                    variant="soft"
                    color={if health == :runner_offline, do: "gray", else: "success"}
                    dot
                    label={if health == :runner_offline, do: "offline", else: "online"}
                    data-testid={"project-status-#{project.directory}"}
                  />
                </p>
              </div>
              <div class="flex flex-wrap gap-2">
                <.button
                  :if={health in [:ok, :runner_offline]}
                  size="xs"
                  icon="hero-plus"
                  link_type="live_redirect"
                  to={~p"/w/#{@current_scope.workspace.slug}/tasks?project_id=#{project.id}"}
                  data-testid={"project-new-task-#{project.directory}"}
                >
                  Nova tarefa
                </.button>
                <.button
                  :if={health in [:ok, :runner_offline]}
                  size="xs"
                  variant="outline"
                  icon="hero-command-line"
                  link_type="live_redirect"
                  to={~p"/w/#{@current_scope.workspace.slug}/jobs?project_id=#{project.id}"}
                  data-testid={"project-new-job-#{project.directory}"}
                >
                  Nova execução
                </.button>
              </div>
              <div :if={can?(@current_scope, :manage_projects)} class="flex gap-2">
                <.button
                  size="xs"
                  variant="outline"
                  color="gray"
                  icon="hero-pencil-square"
                  link_type="live_redirect"
                  to={~p"/w/#{@current_scope.workspace.slug}/projects/#{project.id}/edit"}
                  data-testid={"project-edit-#{project.directory}"}
                >
                  Editar
                </.button>
                <.button
                  size="xs"
                  variant="ghost"
                  color="danger"
                  icon="hero-trash"
                  phx-click="delete"
                  phx-value-id={project.id}
                  data-confirm={"Remover o projeto #{project.name}?"}
                  data-testid={"project-delete-#{project.directory}"}
                >
                  Remover
                </.button>
              </div>
            </div>
            <.alert
              :if={health == :needs_runner}
              color="warning"
              with_icon
              class="mt-3"
              data-testid={"project-needs-runner-#{project.directory}"}
            >
              Este projeto precisa de um runner que ofereça o diretório {project.directory}: edite o projeto e escolha um. Até lá, não recebe trabalho.
            </.alert>
            <.alert
              :if={health == :directory_gone}
              color="warning"
              with_icon
              class="mt-3"
              data-testid={"project-directory-gone-#{project.directory}"}
            >
              O runner {project.runner.name} não oferece mais o diretório {project.directory}: troque o runner do projeto ou devolva o diretório ao runner.
            </.alert>
            <div :if={tasks != []} class="mt-3 text-sm">
              <p class="text-gray-500 dark:text-gray-400">Tarefas recentes</p>
              <ul class="mt-1 space-y-1" data-testid={"project-recent-tasks-#{project.directory}"}>
                <li :for={task <- tasks} class="truncate">
                  <.link
                    navigate={~p"/w/#{@current_scope.workspace.slug}/tasks/#{task.id}"}
                    class="text-primary-600 hover:underline dark:text-primary-400"
                  >
                    {task.title}
                  </.link>
                </li>
              </ul>
            </div>
            <dl class="mt-3 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
              <div :for={
                {label, value} <- [
                  {"Setup", project.setup_command},
                  {"Testes", project.test_command},
                  {"Lint", project.lint_command},
                  {"Copiar para o worktree", Enum.join(project.copy_paths, ", ")}
                ]
              }>
                <dt class="text-gray-500 dark:text-gray-400">{label}</dt>
                <dd class="break-all font-mono text-xs text-gray-900 dark:text-white">
                  {if value in [nil, ""], do: "—", else: value}
                </dd>
              </div>
            </dl>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
