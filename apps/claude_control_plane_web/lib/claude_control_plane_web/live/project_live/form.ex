defmodule ClaudeControlPlaneWeb.ProjectLive.Form do
  @moduledoc """
  Creates or edits a project. The directory is picked among the ones the
  workspace's runners offer.
  """
  use ClaudeControlPlaneWeb, :live_view

  alias ClaudeControlPlane.{Audit, Pipelines, Projects, Runners}
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
       directories: directories(workspace, project),
       pipelines: Pipelines.list_pipelines(workspace)
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
    %{workspace: workspace, user: user} = socket.assigns.current_scope

    result =
      if socket.assigns.project.id,
        do: Projects.update_project(socket.assigns.project, params, user),
        else: Projects.create_project(workspace, params, user)

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
            <details class="mb-4">
              <summary class="cursor-pointer text-sm font-medium text-gray-600 dark:text-gray-300">
                Gatilho do GitHub: uma label numa issue começa uma tarefa
              </summary>
              <div class="mt-3 grid gap-4 sm:grid-cols-3">
                <.field
                  field={@form[:github_repo]}
                  label="Repositório"
                  placeholder="dono/repositorio"
                  data-testid="project-github-repo"
                />
                <.field
                  field={@form[:trigger_label]}
                  label="Label"
                  placeholder="claude"
                  data-testid="project-trigger-label"
                />
                <.field
                  field={@form[:trigger_pipeline_id]}
                  type="select"
                  label="Pipeline"
                  prompt="Escolha um pipeline"
                  options={Enum.map(@pipelines, &{&1.name, &1.id})}
                  data-testid="project-trigger-pipeline"
                />
              </div>
              <p class="text-sm text-gray-600 dark:text-gray-300">
                No GitHub, crie um webhook de <em>Issues</em>
                (content type JSON) para
                <code class="break-all" data-testid="project-webhook-url">{url(
                  ~p"/api/github/webhook/#{@current_scope.workspace.slug}"
                )}</code>
                com o segredo guardado em Segredos como <code>GITHUB_WEBHOOK_SECRET</code>. As tarefas
                ficam em seu nome e rodam num runner online que ofereça este diretório.
              </p>
            </details>
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
