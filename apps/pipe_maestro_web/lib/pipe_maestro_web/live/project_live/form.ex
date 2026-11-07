defmodule PipeMaestroWeb.ProjectLive.Form do
  @moduledoc """
  Creates or edits a project: a runner and one of the directories it offers.
  A new project may be analysed by the agent first ("Analisar com IA", a
  `project` proposal), whose answer fills this same form for review. An
  existing project keeps its directory and can move to another runner that
  offers it.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.{Audit, Integrations, Projects, Proposals, Runners}
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Runners.Runner
  alias PipeMaestroWeb.ChangesetErrors

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
          %Project{workspace_id: workspace.id}
      end

    {:ok,
     socket
     |> assign(
       page_title: if(project.id, do: "Editar projeto", else: "Novo projeto"),
       project: project,
       runners: Runners.list_runners(workspace),
       runner_choices: if(project.id, do: Projects.runner_choices(project), else: []),
       linked_repos: if(project.id, do: Integrations.repos_for_project(project), else: [])
     )
     |> assign_form(Projects.change_project(project))}
  end

  defp assign_form(socket, changeset) do
    form = to_form(changeset)
    assign(socket, form: form, directories: directories(socket.assigns, form))
  end

  # The directories the chosen runner offers; an existing project keeps its own.
  defp directories(%{project: %Project{id: id, directory: directory}}, _form) when id != nil,
    do: [directory]

  defp directories(%{runners: runners}, form) do
    case Enum.find(runners, &(&1.id == form[:runner_id].value)) do
      %Runner{directories: directories} -> directories |> Enum.map(& &1["name"]) |> Enum.sort()
      nil -> []
    end
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    changeset =
      socket.assigns.project |> Projects.change_project(params) |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("analyze", _params, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    form = socket.assigns.form

    attrs = %{"runner_id" => form[:runner_id].value, "directory" => form[:directory].value}

    case Proposals.request("project", user, workspace, attrs) do
      {:ok, job} ->
        {:noreply, push_navigate(socket, to: ~p"/w/#{workspace.slug}/proposals/#{job.id}")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Não deu para analisar: " <> errors(changeset))}
    end
  end

  def handle_event("switch_runner", %{"switch" => %{"runner_id" => runner_id}}, socket) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope

    case Projects.switch_runner(socket.assigns.project, runner_id, user) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Projeto #{project.name} agora roda em #{project.runner.name}.")
         |> push_navigate(to: ~p"/w/#{workspace.slug}/projects")}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Não deu para trocar o runner: " <> errors(changeset))}
    end
  end

  def handle_event("save", %{"project" => params}, socket) do
    workspace = socket.assigns.current_scope.workspace

    result =
      if socket.assigns.project.id,
        do:
          Projects.update_project(
            socket.assigns.project,
            Map.drop(params, ~w(runner_id directory))
          ),
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

  defp errors(changeset) do
    ChangesetErrors.to_text(changeset)
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
              description="Um diretório de código de um runner: é onde as tarefas e execuções dele rodam."
            />
            <div class="grid gap-4 sm:grid-cols-3">
              <.icon_field
                field={@form[:name]}
                icon="hero-tag"
                label="Nome"
                data-testid="project-name"
              />
              <.icon_field
                field={@form[:runner_id]}
                icon="hero-server"
                type="select"
                label="Runner"
                prompt="Escolha o runner"
                options={Enum.map(@runners, &{&1.name, &1.id})}
                disabled={@project.id != nil}
                data-testid="project-runner"
              />
              <.icon_field
                field={@form[:directory]}
                icon="hero-folder-open"
                type="select"
                label="Diretório"
                prompt="Escolha um diretório"
                options={@directories}
                disabled={@project.id != nil}
                help_text="Um dos diretórios que o runner oferece."
                data-testid="project-directory"
              />
            </div>
            <div :if={is_nil(@project.id)} class="flex flex-wrap items-center gap-3">
              <.button
                type="button"
                size="sm"
                variant="outline"
                icon="hero-sparkles"
                phx-click="analyze"
                disabled={
                  @form[:runner_id].value in [nil, ""] or @form[:directory].value in [nil, ""]
                }
                data-testid="project-analyze"
              >
                Analisar com IA
              </.button>
              <span class="text-sm text-gray-500 dark:text-gray-400">
                O agente estuda o diretório num worktree descartável e preenche este formulário para você revisar.
              </span>
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

      <.card :if={@project.id} variant="outline" class="mt-6">
        <.card_content>
          <.section_heading
            icon="hero-arrows-right-left"
            title="Trocar o runner"
            description="Leva o projeto para outro runner que ofereça o mesmo diretório. Tarefas já começadas continuam no runner delas."
          />
          <.form
            for={to_form(%{"runner_id" => @project.runner_id}, as: :switch)}
            id="project-switch-runner-form"
            phx-submit="switch_runner"
            class="flex flex-wrap items-end gap-3"
          >
            <div class="min-w-60 flex-1">
              <.icon_field
                field={to_form(%{"runner_id" => @project.runner_id}, as: :switch)[:runner_id]}
                icon="hero-server"
                type="select"
                label="Novo runner"
                prompt="Escolha o runner"
                options={Enum.map(@runner_choices, &{&1.name, &1.id})}
                no_margin
                data-testid="project-switch-runner"
              />
            </div>
            <.button
              size="sm"
              variant="outline"
              icon="hero-arrows-right-left"
              data-testid="project-switch-runner-save"
            >
              Trocar
            </.button>
          </.form>
        </.card_content>
      </.card>
    </Layouts.app>
    """
  end
end
