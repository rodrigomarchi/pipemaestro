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
      <:action
        :if={can?(@current_scope, :manage_projects)}
        label="Novo projeto"
        icon="hero-plus"
        navigate={~p"/w/#{@current_scope.workspace.slug}/projects/new"}
        primary
        testid="new-project"
      />

      <.record_list id="projects" testid="projects" empty={@projects == []}>
        <.record_card
          :for={%{project: project, health: health, tasks: tasks} <- @projects}
          id={"project-#{project.id}"}
          testid={"project-#{project.directory}"}
          tone={if health in [:needs_runner, :directory_gone], do: :awaiting}
        >
          <:leading><.record_icon icon="hero-folder" color="primary" /></:leading>
          <:title>{project.name}</:title>
          <:badge>
            <.badge
              :if={project.runner}
              size="sm"
              variant="soft"
              color={if health == :runner_offline, do: "gray", else: "success"}
              dot
              label={if health == :runner_offline, do: "offline", else: "online"}
              data-testid={"project-status-#{project.directory}"}
            />
          </:badge>
          <:meta>
            <.record_fact
              icon="hero-server"
              title="Runner"
              testid={"project-runner-#{project.directory}"}
            >
              {if project.runner, do: project.runner.name, else: "sem runner"}
            </.record_fact>
            <.record_fact icon="hero-folder-open" title="Diretório" mono>
              {project.directory}
            </.record_fact>
          </:meta>
          <:body interactive>
            <.alert
              :if={health == :needs_runner}
              color="warning"
              with_icon
              class="mb-3"
              data-testid={"project-needs-runner-#{project.directory}"}
            >
              Este projeto precisa de um runner que ofereça o diretório {project.directory}: edite o projeto e escolha um. Até lá, não recebe trabalho.
            </.alert>
            <.alert
              :if={health == :directory_gone}
              color="warning"
              with_icon
              class="mb-3"
              data-testid={"project-directory-gone-#{project.directory}"}
            >
              O runner {project.runner.name} não oferece mais o diretório {project.directory}: troque o runner do projeto ou devolva o diretório ao runner.
            </.alert>
            <dl class="grid gap-x-6 gap-y-2 sm:grid-cols-2">
              <div :for={
                {label, icon, value} <- [
                  {"Setup", "hero-wrench", project.setup_command},
                  {"Testes", "hero-beaker", project.test_command},
                  {"Lint", "hero-sparkles", project.lint_command},
                  {"Copiar para o worktree", "hero-document-duplicate",
                   Enum.join(project.copy_paths, ", ")}
                ]
              }>
                <dt class="flex items-center gap-1 text-xs text-gray-500 dark:text-gray-400">
                  <.icon name={icon} class="size-3.5 text-gray-400 dark:text-gray-500" />
                  {label}
                </dt>
                <dd class="break-all font-mono text-xs text-gray-900 dark:text-white">
                  {if value in [nil, ""], do: "—", else: value}
                </dd>
              </div>
            </dl>
            <div :if={tasks != []} class="mt-3">
              <p class="flex items-center gap-1 text-xs text-gray-500 dark:text-gray-400">
                <.icon name="hero-queue-list" class="size-3.5 text-gray-400 dark:text-gray-500" />
                Tarefas recentes
              </p>
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
          </:body>
          <:actions>
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
            <.button
              :if={can?(@current_scope, :manage_projects)}
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
              :if={can?(@current_scope, :manage_projects)}
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
          </:actions>
        </.record_card>
        <:empty_state>
          <.record_empty
            testid="no-projects"
            icon="hero-folder"
            title="Nenhum projeto ainda"
            description="Um projeto é um diretório de código de um runner: é onde as tarefas rodam. Ele diz como preparar o worktree (setup e o que copiar), como testar e o que os agentes devem saber."
          />
        </:empty_state>
      </.record_list>
    </Layouts.app>
    """
  end
end
