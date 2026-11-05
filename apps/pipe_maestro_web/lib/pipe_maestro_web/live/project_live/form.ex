defmodule PipeMaestroWeb.ProjectLive.Form do
  @moduledoc """
  Creates or edits a project: a runner and one of the directories it offers.
  A new project may be analysed by the agent first ("Analisar com IA", a
  `project` proposal), whose answer fills this same form for review. An
  existing project keeps its directory and can move to another runner that
  offers it.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.{Audit, Pipelines, Projects, Proposals, Runners}
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Runners.Runner

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
       pipelines: Pipelines.list_pipelines(workspace)
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
    %{workspace: workspace, user: user} = socket.assigns.current_scope

    result =
      if socket.assigns.project.id,
        do:
          Projects.update_project(
            socket.assigns.project,
            Map.drop(params, ~w(runner_id directory)),
            user
          ),
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

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {_field, messages} -> messages end)
    |> Enum.join("; ")
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
              <.icon_field
                field={@form[:trigger_mode]}
                icon="hero-funnel"
                type="select"
                label="Ao receber a issue"
                options={[
                  {"Começar a tarefa direto", "task"},
                  {"O agente escreve a tarefa antes (triagem), e alguém revisa", "triage"}
                ]}
                data-testid="project-trigger-mode"
              />
              <p class="flex gap-2 text-sm text-gray-600 dark:text-gray-300">
                <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-primary-500" />
                <span>
                  No GitHub, crie um webhook de <em>Issues</em>
                  (content type JSON) para
                  <code class="break-all" data-testid="project-webhook-url">{url(
                    ~p"/api/github/webhook/#{@current_scope.workspace.slug}"
                  )}</code>
                  com o segredo guardado em Segredos como <code>GITHUB_WEBHOOK_SECRET</code>. As tarefas
                  ficam em seu nome e rodam no runner do projeto (esperando por ele, se estiver offline).
                </span>
              </p>
            </details>
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
