defmodule PipeMaestroWeb.PipelineLive.Index do
  @moduledoc """
  The workspace's pipelines, with their stages and version. An empty
  workspace starts from the ready-made ones. A pipeline exports as YAML, and
  YAML imports as a new pipeline (`PipeMaestro.Pipelines.Yaml`). An admin
  also asks the agent, through a runner, to study a directory and propose a
  pipeline and its project (`PipeMaestro.Proposals`); the latest proposals
  are listed here.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.Audit
  alias PipeMaestro.Jobs
  alias PipeMaestro.Pipelines
  alias PipeMaestro.Proposals
  alias PipeMaestro.Runners
  alias PipeMaestroWeb.RunnerStatus

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Jobs.subscribe({:workspace, socket.assigns.current_scope.workspace.id})

    {:ok,
     socket
     |> assign(page_title: "Pipelines", exported: nil, importing: false, import_error: nil)
     |> assign(generating: false, generate_form: nil, generate_params: %{}, online_runners: [])
     |> load_pipelines()
     |> load_proposals()}
  end

  # A proposal's status changes as its job runs.
  @impl true
  def handle_info({:job_updated, job}, socket) do
    if Proposals.proposal?(job),
      do: {:noreply, load_proposals(socket)},
      else: {:noreply, socket}
  end

  @admin_events ~w(create_defaults open_import import delete open_generate validate_generate generate)

  @impl true
  def handle_event(event, params, socket) when event in @admin_events do
    if can?(socket.assigns.current_scope, :manage_pipelines),
      do: admin_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, "Só admins do workspace mudam os pipelines.")}
  end

  def handle_event("export", %{"id" => id}, socket) do
    pipeline = Pipelines.get_pipeline!(socket.assigns.current_scope.workspace, id)

    {:noreply,
     assign(socket, exported: %{pipeline: pipeline, yaml: Pipelines.export_yaml(pipeline)})}
  end

  def handle_event("close_yaml", _params, socket), do: {:noreply, assign(socket, exported: nil)}

  def handle_event("close_import", _params, socket),
    do: {:noreply, assign(socket, importing: false)}

  def handle_event("close_generate", _params, socket),
    do: {:noreply, assign(socket, generating: false)}

  defp admin_event("create_defaults", _params, socket) do
    created = Pipelines.create_defaults(socket.assigns.current_scope.workspace)

    {:noreply,
     socket
     |> put_flash(:info, "#{length(created)} pipeline(s) padrão criado(s).")
     |> load_pipelines()}
  end

  defp admin_event("open_import", _params, socket),
    do: {:noreply, assign(socket, importing: true, import_error: nil)}

  defp admin_event("import", %{"import" => %{"yaml" => yaml}}, socket) do
    case Pipelines.import_yaml(socket.assigns.current_scope.workspace, yaml) do
      {:ok, pipeline} ->
        audit(socket, "pipeline.imported", pipeline)

        {:noreply,
         socket
         |> assign(importing: false)
         |> put_flash(:info, "Pipeline #{pipeline.name} importado.")
         |> load_pipelines()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, import_error: changeset_message(changeset))}

      {:error, message} ->
        {:noreply, assign(socket, import_error: message)}
    end
  end

  defp admin_event("open_generate", _params, socket) do
    {:noreply,
     socket
     |> load_online_runners()
     |> assign(generating: true, generate_params: %{})
     |> assign(generate_form: to_form(Proposals.change_request(), as: "proposal"))}
  end

  defp admin_event("validate_generate", %{"proposal" => params}, socket) do
    form =
      params
      |> Proposals.change_request()
      |> Map.put(:action, :validate)
      |> to_form(as: "proposal")

    {:noreply, assign(socket, generate_params: params, generate_form: form)}
  end

  defp admin_event("generate", %{"proposal" => params}, socket) do
    %{user: user, workspace: workspace} = socket.assigns.current_scope

    case Proposals.request(user, workspace, params) do
      {:ok, job} ->
        audit(socket, "proposal.requested", job)

        {:noreply,
         push_navigate(socket, to: ~p"/w/#{workspace.slug}/pipelines/proposals/#{job.id}")}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           generate_params: params,
           generate_form: to_form(Map.put(changeset, :action, :insert), as: "proposal")
         )}
    end
  end

  defp admin_event("delete", %{"id" => id}, socket) do
    pipeline = Pipelines.get_pipeline!(socket.assigns.current_scope.workspace, id)
    {:ok, _} = Pipelines.delete_pipeline(pipeline)
    audit(socket, "pipeline.deleted", pipeline)

    {:noreply,
     socket
     |> put_flash(:info, "Pipeline #{pipeline.name} removido.")
     |> load_pipelines()}
  end

  defp audit(socket, action, subject) do
    %{workspace: workspace, user: user} = socket.assigns.current_scope
    Audit.record(workspace, user, action, subject)
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> inspect(pretty: true)
    |> then(&"O pipeline não é válido: #{&1}")
  end

  defp file_name(name) do
    slug =
      name
      |> String.normalize(:nfd)
      |> String.replace(~r/[^\x00-\x7F]/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    slug <> ".yaml"
  end

  defp load_proposals(socket),
    do: assign(socket, proposals: Proposals.list_recent(socket.assigns.current_scope.workspace))

  defp load_online_runners(socket) do
    workspace = socket.assigns.current_scope.workspace
    online = RunnerStatus.online_ids(workspace.id)

    runners =
      for runner <- Runners.list_runners(workspace), MapSet.member?(online, runner.id), do: runner

    assign(socket, online_runners: runners)
  end

  # Runners that cannot run an analysis are listed, but cannot be picked.
  defp runner_options(runners) do
    for runner <- runners do
      if Proposals.capable?(runner),
        do: [key: runner.name, value: runner.id],
        else: [key: "#{runner.name} (atualize o runner)", value: runner.id, disabled: true]
    end
  end

  # Only git directories can be analysed: the agent works in a worktree.
  defp directory_options(runners, runner_id) do
    case Enum.find(runners, &(&1.id == runner_id)) do
      nil -> []
      runner -> for %{"name" => name, "git" => true} <- runner.directories, do: {name, name}
    end
  end

  defp proposal_status(job) do
    case job.status do
      :queued -> {"Na fila", "gray"}
      :running -> {"Analisando", "info"}
      :succeeded -> {"Pronta", "success"}
      :failed -> {"Falhou", "danger"}
      :canceled -> {"Cancelada", "gray"}
    end
  end

  defp load_pipelines(socket),
    do:
      assign(socket, pipelines: Pipelines.list_pipelines(socket.assigns.current_scope.workspace))

  defp delivery_icon("pr"), do: "hero-rocket-launch"
  defp delivery_icon("commit"), do: "hero-check-badge"
  defp delivery_icon(_none), do: "hero-no-symbol"

  defp delivery_label("pr"), do: "Pull request"
  defp delivery_label("commit"), do: "Commit por etapa"
  defp delivery_label(_none), do: "Sem entrega"

  defp budget_label(nil), do: "Sem teto"
  defp budget_label(cost), do: "Até US$ #{cost}"

  defp stages_label(1), do: "1 etapa"
  defp stages_label(count), do: "#{count} etapas"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:pipelines}
      title="Pipelines"
    >
      <:actions>
        <.button
          :if={can?(@current_scope, :manage_pipelines)}
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-arrow-up-tray"
          phx-click="open_import"
          data-testid="import-pipeline"
        >
          Importar
        </.button>
        <.button
          :if={can?(@current_scope, :manage_pipelines)}
          size="sm"
          icon="hero-cpu-chip"
          phx-click="open_generate"
          data-testid="generate-pipeline"
        >
          Gerar com IA
        </.button>
        <.button
          :if={can?(@current_scope, :manage_pipelines)}
          size="sm"
          variant="outline"
          icon="hero-sparkles"
          phx-click="create_defaults"
          data-testid="create-default-pipelines"
        >
          Criar pipelines padrão
        </.button>
        <.button
          :if={can?(@current_scope, :manage_pipelines)}
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/pipelines/new"}
          size="sm"
          icon="hero-plus"
          data-testid="new-pipeline"
        >
          Novo pipeline
        </.button>
      </:actions>

      <.card :if={@pipelines == []} variant="outline">
        <.card_content>
          <.empty
            data-testid="no-pipelines"
            title="Nenhum pipeline ainda"
            description="Comece pelos pipelines padrão (correção de bug, funcionalidade, refatoração, revisão, investigação de produção e outros) e ajuste os prompts ao seu time."
          >
            <:icon><.icon name="hero-squares-2x2" /></:icon>
            <:actions>
              <.button icon="hero-sparkles" phx-click="create_defaults">
                Criar pipelines padrão
              </.button>
            </:actions>
          </.empty>
        </.card_content>
      </.card>

      <.card :if={@proposals != []} variant="outline" class="mb-6" data-testid="proposals">
        <.card_content>
          <.section_heading
            icon="hero-cpu-chip"
            title="Propostas do agente"
            description="Pipelines e projetos que o agente propôs depois de estudar um diretório."
          />
          <ul class="divide-y divide-gray-100 dark:divide-gray-800">
            <li :for={job <- @proposals} class="flex items-center gap-3 py-2.5">
              <.icon name="hero-folder-open" class="size-5 shrink-0 text-gray-400" />
              <div class="min-w-0 flex-1">
                <.link
                  navigate={~p"/w/#{@current_scope.workspace.slug}/pipelines/proposals/#{job.id}"}
                  class="font-medium text-gray-900 hover:underline dark:text-white"
                  data-testid={"proposal-link-#{job.id}"}
                >
                  {Proposals.asked(job).directory}
                </.link>
                <p class="truncate text-xs text-gray-500 dark:text-gray-400">
                  {Proposals.asked(job).request}
                </p>
              </div>
              <span class="hidden shrink-0 text-xs text-gray-500 sm:inline dark:text-gray-400">
                {job.runner && job.runner.name}
              </span>
              <.badge
                size="sm"
                variant="soft"
                color={elem(proposal_status(job), 1)}
                label={elem(proposal_status(job), 0)}
                data-testid={"proposal-status-#{job.id}"}
              />
            </li>
          </ul>
        </.card_content>
      </.card>

      <div class="grid gap-4 lg:grid-cols-2">
        <.card
          :for={pipeline <- @pipelines}
          variant="outline"
          data-testid={"pipeline-#{pipeline.name}"}
        >
          <.card_content class="flex h-full flex-col">
            <div class="flex items-start gap-3">
              <span class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary-50 text-primary-600 dark:bg-primary-950 dark:text-primary-300">
                <.icon name="hero-squares-2x2" class="size-5" />
              </span>
              <div class="min-w-0 flex-1">
                <div class="flex items-center justify-between gap-3">
                  <h3 class="truncate font-semibold text-gray-900 dark:text-white">
                    {pipeline.name}
                  </h3>
                  <.badge
                    size="sm"
                    variant="outline"
                    color="gray"
                    label={"v#{pipeline.version}"}
                    data-testid={"pipeline-version-#{pipeline.name}"}
                  />
                </div>
                <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">{pipeline.description}</p>
              </div>
            </div>
            <dl
              class="mt-4 flex flex-wrap gap-x-4 gap-y-1 text-xs text-gray-500 dark:text-gray-400"
              data-testid={"pipeline-meta-#{pipeline.name}"}
            >
              <div class="flex items-center gap-1">
                <dt><.icon name={delivery_icon(pipeline.delivery)} class="size-4" /></dt>
                <dd>{delivery_label(pipeline.delivery)}</dd>
              </div>
              <div class="flex items-center gap-1">
                <dt><.icon name="hero-banknotes" class="size-4" /></dt>
                <dd>{budget_label(pipeline.max_task_cost_usd)}</dd>
              </div>
              <div class="flex items-center gap-1">
                <dt><.icon name="hero-queue-list" class="size-4" /></dt>
                <dd>{stages_label(length(pipeline.stages))}</dd>
              </div>
            </dl>
            <ol class="mt-4 flex-1 space-y-1.5">
              <li
                :for={{stage, index} <- Enum.with_index(pipeline.stages)}
                class="flex items-center gap-2.5 text-sm"
              >
                <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-primary-50 text-xs font-semibold text-primary-700 dark:bg-primary-950 dark:text-primary-300">
                  {index + 1}
                </span>
                <span class="min-w-0 truncate text-gray-700 dark:text-gray-200">{stage.name}</span>
                <span class="ml-auto flex shrink-0 items-center gap-1.5 text-gray-400 dark:text-gray-500">
                  <span :if={stage.group} title={"Em paralelo: #{stage.group}"}>
                    <.icon name="hero-squares-2x2" class="size-4" />
                  </span>
                  <span :if={stage.gates != []} title={"#{length(stage.gates)} gates"}>
                    <.icon name="hero-shield-check" class="size-4" />
                  </span>
                  <span :if={stage.rules != []} title="Pede ajuda quando uma regra casa">
                    <.icon name="hero-hand-raised" class="size-4" />
                  </span>
                  <span :if={stage.model} title={"Modelo #{stage.model}"}>
                    <.icon name="hero-sparkles" class="size-4" />
                  </span>
                </span>
              </li>
            </ol>
            <div class="mt-4 flex justify-end gap-1 border-t border-gray-100 pt-3 dark:border-gray-800">
              <.button
                size="xs"
                variant="ghost"
                color="gray"
                icon="hero-arrow-down-tray"
                phx-click="export"
                phx-value-id={pipeline.id}
                data-testid={"pipeline-export-#{pipeline.name}"}
              >
                Exportar
              </.button>
              <.button
                :if={can?(@current_scope, :manage_pipelines)}
                link_type="live_redirect"
                to={~p"/w/#{@current_scope.workspace.slug}/pipelines/#{pipeline.id}/edit"}
                size="xs"
                variant="ghost"
                color="gray"
                icon="hero-pencil-square"
                data-testid={"pipeline-edit-#{pipeline.name}"}
              >
                Editar
              </.button>
              <.button
                :if={can?(@current_scope, :manage_pipelines)}
                size="xs"
                variant="ghost"
                color="danger"
                icon="hero-trash"
                phx-click="delete"
                phx-value-id={pipeline.id}
                data-confirm={"Remover #{pipeline.name}? Tarefas que já o usaram não mudam."}
                data-testid={"pipeline-delete-#{pipeline.name}"}
              >
                Remover
              </.button>
            </div>
          </.card_content>
        </.card>
      </div>

      <.modal
        :if={@exported}
        id="export-modal"
        title={"#{@exported.pipeline.name} em YAML"}
        max_width="xl"
        on_cancel={JS.push("close_yaml")}
      >
        <pre
          class="max-h-[60vh] overflow-auto rounded-lg bg-gray-50 px-4 py-3 font-mono text-xs text-gray-800 dark:bg-gray-950 dark:text-gray-100"
          data-testid="pipeline-yaml"
        >{@exported.yaml}</pre>
        <div class="mt-4 flex justify-end">
          <a
            href={"data:application/yaml;charset=utf-8," <> URI.encode(@exported.yaml, &URI.char_unreserved?/1)}
            download={file_name(@exported.pipeline.name)}
            class="inline-flex items-center gap-2 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white hover:bg-primary-700"
            data-testid="pipeline-yaml-download"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Baixar
          </a>
        </div>
      </.modal>

      <.modal
        :if={@generating}
        id="generate-modal"
        title="Gerar pipeline com IA"
        max_width="xl"
        on_cancel={JS.push("close_generate")}
      >
        <p class="mb-4 text-sm text-gray-600 dark:text-gray-300">
          O agente estuda o diretório pelo runner, num worktree descartável (nada muda no seu
          código), roda os comandos que encontrar e propõe a configuração do projeto e um
          pipeline. Você revisa antes de salvar.
        </p>
        <.alert
          :if={@online_runners == []}
          color="warning"
          class="mb-4"
          data-testid="generate-no-runners"
        >
          Nenhum runner online. Conecte um em Executores.
        </.alert>
        <.form
          for={@generate_form}
          id="generate-form"
          phx-change="validate_generate"
          phx-submit="generate"
        >
          <div class="grid gap-4 sm:grid-cols-2">
            <.icon_field
              field={@generate_form[:runner_id]}
              icon="hero-server-stack"
              type="select"
              label="Runner"
              prompt="Escolha um runner online"
              options={runner_options(@online_runners)}
              data-testid="generate-runner"
            />
            <.icon_field
              field={@generate_form[:directory]}
              icon="hero-folder-open"
              type="select"
              label="Diretório (repositório git)"
              prompt="Escolha um diretório"
              options={directory_options(@online_runners, @generate_params["runner_id"])}
              data-testid="generate-directory"
            />
          </div>
          <.markdown_editor
            id="generate-request"
            field={@generate_form[:request]}
            label="O que o pipeline deve fazer"
            icon="hero-chat-bubble-bottom-center-text"
            testid="generate-request"
            rows={6}
            placeholder="Ex.: implementar funcionalidades a partir de issues do GitHub, com testes, revisão e um PR no final."
          />
          <div class="flex justify-end gap-2">
            <.button type="button" variant="ghost" color="gray" phx-click="close_generate">
              Cancelar
            </.button>
            <.button type="submit" icon="hero-cpu-chip" data-testid="generate-submit">
              Analisar e propor
            </.button>
          </div>
        </.form>
      </.modal>

      <.modal
        :if={@importing}
        id="import-modal"
        title="Importar pipeline"
        max_width="xl"
        on_cancel={JS.push("close_import")}
      >
        <.form for={to_form(%{"yaml" => ""}, as: "import")} id="import-form" phx-submit="import">
          <.icon_field
            field={to_form(%{"yaml" => ""}, as: "import")[:yaml]}
            icon="hero-document-arrow-up"
            type="textarea"
            rows="14"
            label="YAML exportado de um pipeline"
            data-testid="import-yaml"
          />
          <.alert :if={@import_error} color="danger" class="mb-4" data-testid="import-error">
            {@import_error}
          </.alert>
          <div class="flex justify-end">
            <.button icon="hero-arrow-up-tray" data-testid="import-submit">Importar</.button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
