defmodule ClaudeControlPlaneWeb.ProjectLive.Index do
  @moduledoc """
  The workspace's projects: for each code directory, the commands that set up
  a task's worktree, test and lint it.
  """
  use ClaudeControlPlaneWeb, :live_view

  alias ClaudeControlPlane.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Projetos") |> load_projects()}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    project = Projects.get_project!(socket.assigns.current_scope.workspace, id)
    {:ok, _} = Projects.delete_project(project)

    {:noreply, socket |> put_flash(:info, "Projeto #{project.name} removido.") |> load_projects()}
  end

  defp load_projects(socket),
    do: assign(socket, projects: Projects.list_projects(socket.assigns.current_scope.workspace))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:projects}
      title="Projetos"
    >
      <:actions>
        <.button
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
            description="Um projeto diz como preparar o worktree de uma tarefa num diretório (setup e o que copiar), como testar e o que os agentes devem saber."
          >
            <:icon><.icon name="hero-folder" /></:icon>
          </.empty>
        </.card_content>
      </.card>

      <div class="space-y-4">
        <.card
          :for={project <- @projects}
          variant="outline"
          data-testid={"project-#{project.directory}"}
        >
          <.card_content>
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="font-semibold text-gray-900 dark:text-white">{project.name}</p>
                <p class="font-mono text-xs text-gray-500 dark:text-gray-400">
                  {project.directory}
                </p>
              </div>
              <div class="flex gap-2">
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
