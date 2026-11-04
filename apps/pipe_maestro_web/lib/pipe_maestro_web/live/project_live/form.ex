defmodule PipeMaestroWeb.ProjectLive.Form do
  @moduledoc """
  Creates or edits a project. The directory is picked among the ones the
  workspace's runners offer.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.{Audit, Pipelines, Projects, Runners}
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
            <details class="group">
              <summary class="flex cursor-pointer list-none items-start gap-3">
                <span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary-50 text-primary-600 dark:bg-primary-950 dark:text-primary-300">
                  <.icon name="hero-bolt" class="size-5" />
                </span>
                <span class="flex-1">
                  <span class="flex items-center gap-1.5 font-semibold text-gray-900 dark:text-white">
                    Gatilho do GitHub
                    <.icon
                      name="hero-chevron-down"
                      class="size-4 text-gray-400 transition group-open:rotate-180"
                    />
                  </span>
                  <span class="block text-sm text-gray-500 dark:text-gray-400">
                    Uma label numa issue começa uma tarefa.
                  </span>
                </span>
              </summary>
              <div class="mt-5 grid gap-4 sm:grid-cols-3">
                <.icon_field
                  field={@form[:github_repo]}
                  icon="hero-code-bracket-square"
                  label="Repositório"
                  placeholder="dono/repositorio"
                  data-testid="project-github-repo"
                />
                <.icon_field
                  field={@form[:trigger_label]}
                  icon="hero-tag"
                  label="Label"
                  placeholder="claude"
                  data-testid="project-trigger-label"
                />
                <.icon_field
                  field={@form[:trigger_pipeline_id]}
                  icon="hero-squares-2x2"
                  type="select"
                  label="Pipeline"
                  prompt="Escolha um pipeline"
                  options={Enum.map(@pipelines, &{&1.name, &1.id})}
                  data-testid="project-trigger-pipeline"
                />
              </div>
              <p class="flex gap-2 text-sm text-gray-600 dark:text-gray-300">
                <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-primary-500" />
                <span>
                  No GitHub, crie um webhook de <em>Issues</em>
                  (content type JSON) para
                  <code class="break-all" data-testid="project-webhook-url">{url(
                    ~p"/api/github/webhook/#{@current_scope.workspace.slug}"
                  )}</code>
                  com o segredo guardado em Segredos como <code>GITHUB_WEBHOOK_SECRET</code>. As tarefas
                  ficam em seu nome e rodam num runner online que ofereça este diretório.
                </span>
              </p>
            </details>
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
