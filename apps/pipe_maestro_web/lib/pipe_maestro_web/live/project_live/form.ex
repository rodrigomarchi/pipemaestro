defmodule PipeMaestroWeb.ProjectLive.Form do
  @moduledoc """
  Creates or edits a project. The directory is picked among the ones the
  workspace's runners offer.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.{Audit, Integrations, Projects, Runners}
  alias PipeMaestro.Projects.Project

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
       linked_repos: if(project.id, do: Integrations.repos_for_project(project), else: [])
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

  # A multi-line placeholder: in the template, the formatter would make it literal.
  defp copy_paths_placeholder, do: Enum.join(~w(deps _build node_modules), "\n")

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

      <.form for={@form} id="project-form" phx-change="validate" phx-submit="save" class="space-y-6">
        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon="hero-folder"
              title="Projeto"
              description="Um diretório de código que recebe tarefas, em qualquer runner que o ofereça."
            />
            <div class="grid gap-4 sm:grid-cols-2">
              <.icon_field
                field={@form[:name]}
                icon="hero-tag"
                label="Nome"
                data-testid="project-name"
              />
              <.icon_field
                field={@form[:directory]}
                icon="hero-folder-open"
                type="select"
                label="Diretório"
                prompt="Escolha um diretório"
                options={@directories}
                help_text="Vale em qualquer runner que ofereça um diretório com esse nome."
                data-testid="project-directory"
              />
            </div>
          </.card_content>
        </.card>

        <div class="grid gap-6 lg:grid-cols-2">
          <.card variant="outline">
            <.card_content>
              <.section_heading
                icon="hero-wrench-screwdriver"
                title="Worktree"
                description="Como o worktree de cada tarefa fica pronto para trabalhar."
              />
              <.icon_field
                field={@form[:setup_command]}
                icon="hero-play"
                label="Comando de setup"
                placeholder="mix deps.get && mix compile"
                help_text="Roda uma vez, quando o worktree da tarefa é criado."
                class="font-mono text-sm"
                data-testid="project-setup"
              />
              <.icon_field
                field={@form[:copy_paths_text]}
                icon="hero-document-duplicate"
                type="textarea"
                rows="3"
                label="Copiar para o worktree (um por linha)"
                placeholder={copy_paths_placeholder()}
                help_text="Clonados do checkout por copy-on-write. Em branco, o runner detecta os usuais."
                class="font-mono text-sm"
                no_margin
                data-testid="project-copy-paths"
              />
            </.card_content>
          </.card>

          <.card variant="outline">
            <.card_content>
              <.section_heading
                icon="hero-command-line"
                title="Comandos"
                description="O que as etapas e os gates usam para verificar o trabalho."
              />
              <.icon_field
                field={@form[:test_command]}
                icon="hero-beaker"
                label="Comando de testes"
                placeholder="mix test"
                help_text="Nos prompts: {{projeto.teste}}; nos gates das etapas."
                class="font-mono text-sm"
                data-testid="project-test"
              />
              <.icon_field
                field={@form[:lint_command]}
                icon="hero-sparkles"
                label="Comando de lint"
                placeholder="mix credo --strict"
                help_text="Nos prompts: {{projeto.lint}}."
                class="font-mono text-sm"
                no_margin
                data-testid="project-lint"
              />
            </.card_content>
          </.card>
        </div>

        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon="hero-chat-bubble-left-ellipsis"
              title="Contexto para os agentes"
              description="O que todo agente precisa saber deste projeto."
            />
            <.markdown_editor
              id="project-notes"
              field={@form[:notes]}
              label="Notas para os agentes"
              icon="hero-light-bulb"
              rows={6}
              help_text="Nos prompts: {{projeto.notas}}."
              testid="project-notes"
            />
          </.card_content>
        </.card>

        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon="hero-link"
              title="Issues que viram tarefas"
              description="Um repositório do Forgejo ou do GitHub ligado a este projeto, em Integrações."
            />
            <ul :if={@linked_repos != []} class="space-y-1 text-sm" data-testid="project-linked-repos">
              <li :for={repo <- @linked_repos} class="flex items-center gap-2">
                <.icon name="hero-code-bracket-square" class="size-4 text-gray-400" />
                <.link
                  navigate={
                    ~p"/w/#{@current_scope.workspace.slug}/integrations/#{repo.connection_id}/repos/#{repo.id}"
                  }
                  class="font-mono text-primary-600 hover:underline dark:text-primary-400"
                >
                  {repo.full_name}
                </.link>
                <span class="text-xs text-gray-500 dark:text-gray-400">({repo.connection.name})</span>
              </li>
            </ul>
            <p :if={@linked_repos == []} class="text-sm text-gray-500 dark:text-gray-400">
              Nenhum repositório ligado.
              <.link
                navigate={~p"/w/#{@current_scope.workspace.slug}/integrations"}
                class="text-primary-600 hover:underline dark:text-primary-400"
                data-testid="project-integrations-link"
              >
                Conectar em Integrações
              </.link>
            </p>
          </.card_content>
        </.card>

        <div class="sticky bottom-0 z-10 flex justify-end rounded-xl border border-gray-200 bg-white/90 px-4 py-3 shadow-lg backdrop-blur dark:border-gray-700 dark:bg-gray-900/90">
          <.button icon="hero-check" data-testid="project-save">Salvar</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
