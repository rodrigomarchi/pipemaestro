defmodule PipeMaestroWeb.PipelineLive.Index do
  @moduledoc """
  The workspace's pipelines, each with its version and a small diagram of
  its stages (`PipeMaestroWeb.PipelineComponents.pipeline_diagram/1`); the
  name leads to the pipeline's page. An empty
  workspace starts from the ready-made ones. A pipeline exports as YAML, and
  YAML imports as a new pipeline (`PipeMaestro.Pipelines.Yaml`). An admin
  also asks the agent (`PipeMaestro.Proposals`, through
  `PipeMaestroWeb.ProposalRequest`) to propose a pipeline from a directory,
  or to improve one from how its tasks went.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.Audit
  alias PipeMaestro.Pipelines
  alias PipeMaestroWeb.{ChangesetErrors, Markdown, PipelineDiagram, ProposalRequest}

  import PipeMaestroWeb.PipelineComponents,
    only: [budget_label: 1, delivery_icon: 1, delivery_label: 1, pipeline_diagram: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Pipelines", exported: nil, importing: false, import_error: nil)
     |> assign(proposal_request: nil)
     |> load_pipelines()}
  end

  @admin_events ~w(create_defaults open_import import delete open_generate open_improve
                   validate_proposal_request submit_proposal_request)

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

  def handle_event("close_proposal_request", _params, socket),
    do: {:noreply, ProposalRequest.close(socket)}

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

  defp admin_event("open_generate", _params, socket),
    do: {:noreply, ProposalRequest.open(socket, "pipeline")}

  # The pipeline's project is the one its last finished task ran in, if any.
  defp admin_event("open_improve", %{"id" => id}, socket) do
    pipeline = Pipelines.get_pipeline!(socket.assigns.current_scope.workspace, id)

    {:noreply,
     ProposalRequest.open(socket, "improve",
       fixed: %{"pipeline_id" => pipeline.id},
       project_id: pipeline_project_id(pipeline)
     )}
  end

  defp admin_event("validate_proposal_request", %{"proposal" => params}, socket),
    do: {:noreply, ProposalRequest.validate(socket, params)}

  defp admin_event("submit_proposal_request", %{"proposal" => params}, socket),
    do: {:noreply, ProposalRequest.submit(socket, params)}

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
    "O pipeline não é válido: " <> ChangesetErrors.to_text(changeset)
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

  defp pipeline_project_id(pipeline) do
    case PipeMaestro.Tasks.history(pipeline, 1) do
      [task | _] -> task.project_id
      [] -> nil
    end
  end

  defp load_pipelines(socket),
    do:
      assign(socket, pipelines: Pipelines.list_pipelines(socket.assigns.current_scope.workspace))

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
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/proposals"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-cpu-chip"
          data-testid="pipelines-proposals"
        >
          Propostas
        </.button>
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

      <div class="space-y-4">
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
                    <.link
                      navigate={~p"/w/#{@current_scope.workspace.slug}/pipelines/#{pipeline.id}"}
                      class="hover:text-primary-600 dark:hover:text-primary-400"
                      data-testid={"pipeline-open-#{pipeline.name}"}
                    >
                      {pipeline.name}
                    </.link>
                  </h3>
                  <.badge
                    size="sm"
                    variant="outline"
                    color="gray"
                    label={"v#{pipeline.version}"}
                    data-testid={"pipeline-version-#{pipeline.name}"}
                  />
                </div>
                <div class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                  {Markdown.inline_html(pipeline.description)}
                </div>
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
            <.pipeline_diagram
              diagram={PipelineDiagram.build(pipeline)}
              mode={:compact}
              class="mt-4 flex-1"
              testid={"pipeline-preview-#{pipeline.name}"}
            />
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
                size="xs"
                variant="ghost"
                color="gray"
                icon="hero-arrow-trending-up"
                phx-click="open_improve"
                phx-value-id={pipeline.id}
                data-testid={"pipeline-improve-#{pipeline.name}"}
              >
                Melhorar com IA
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

      <ProposalRequest.request_modal :if={@proposal_request} request={@proposal_request} />

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
