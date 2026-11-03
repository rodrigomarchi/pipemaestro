defmodule ClaudeControlPlaneWeb.ProjectLive.Form do
  @moduledoc """
  Creates or edits a project. The directory is picked among the ones the
  workspace's runners offer.
  """
  use ClaudeControlPlaneWeb, :live_view

  alias ClaudeControlPlane.Audit
  alias ClaudeControlPlane.{Projects, Runners}
  alias ClaudeControlPlane.Projects.Project

  @impl true
  def mount(params, session, socket) do
    if can?(socket.assigns.current_scope, :manage_projects),
      do: mount_form(params, session, socket),
      else:
        {:ok,
         socket
         |> put_flash(:error, "Só admins do workspace mudam os projetos.")
         |> push_navigate(to: ~p"/w/#{socket.assigns.current_scope.workspace.slug}/projects")}
  end

  defp mount_form(params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace

    project =
      case params do
        %{"id" => id} ->
          project = Projects.get_project!(workspace, id)
          %{project | copy_paths_text: Enum.join(project.copy_paths, "\n")}

        _new ->
          %Project{}
      end

    {:ok,
     socket
     |> assign(
       page_title: if(project.id, do: "Editar projeto", else: "Novo projeto"),
       project: project,
       directories: directories(workspace, project)
     )
     |> assign_form(Projects.change_project(project))}
  end

  # Every directory the runners offer, plus the project's own.
  defp directories(workspace, project) do
    workspace
    |> Runners.list_runners()
    |> Enum.flat_map(fn runner -> Enum.map(runner.directories, & &1["name"]) end)
    |> Kernel.++(List.wrap(project.directory))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset))

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    changeset =
      socket.assigns.project |> Projects.change_project(params) |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"project" => params}, socket) do
    workspace = socket.assigns.current_scope.workspace

    result =
      if socket.assigns.project.id,
        do: Projects.update_project(socket.assigns.project, params),
        else: Projects.create_project(workspace, params)

    case result do
      {:ok, project} ->
        Audit.record(workspace, socket.assigns.current_scope.user, "project.saved", project)

        {:noreply,
         socket
         |> put_flash(:info, "Projeto #{project.name} salvo.")
         |> push_navigate(to: ~p"/w/#{workspace.slug}/projects")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:projects}
      title={@page_title}
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/projects"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
        >
          Projetos
        </.button>
      </:actions>

      <.card variant="outline">
        <.card_content>
          <.form for={@form} id="project-form" phx-change="validate" phx-submit="save">
            <div class="grid gap-4 sm:grid-cols-2">
              <.field field={@form[:name]} label="Nome" data-testid="project-name" />
              <.field
                field={@form[:directory]}
                type="select"
                label="Diretório"
                prompt="Escolha um diretório"
                options={@directories}
                help_text="Vale em qualquer runner que ofereça um diretório com esse nome."
                data-testid="project-directory"
              />
            </div>
            <.field
              field={@form[:setup_command]}
              label="Comando de setup"
              placeholder="mix deps.get && mix compile"
              help_text="Roda uma vez, quando o worktree da tarefa é criado."
              data-testid="project-setup"
            />
            <div class="grid gap-4 sm:grid-cols-2">
              <.field
                field={@form[:test_command]}
                label="Comando de testes"
                placeholder="mix test"
                help_text="Nos prompts: {{projeto.teste}}; nos gates das etapas."
                data-testid="project-test"
              />
              <.field
                field={@form[:lint_command]}
                label="Comando de lint"
                placeholder="mix credo --strict"
                help_text="Nos prompts: {{projeto.lint}}."
                data-testid="project-lint"
              />
            </div>
            <.field
              field={@form[:copy_paths_text]}
              type="textarea"
              rows="3"
              label="Copiar para o worktree (um por linha)"
              placeholder="deps\n_build\nnode_modules"
              help_text="Clonados do checkout por copy-on-write. Em branco, o runner detecta os usuais."
              data-testid="project-copy-paths"
            />
            <.field
              field={@form[:notes]}
              type="textarea"
              rows="4"
              label="Notas para os agentes"
              help_text="Nos prompts: {{projeto.notas}}."
              data-testid="project-notes"
            />
            <div class="flex justify-end">
              <.button icon="hero-check" data-testid="project-save">Salvar</.button>
            </div>
          </.form>
        </.card_content>
      </.card>
    </Layouts.app>
    """
  end
end
