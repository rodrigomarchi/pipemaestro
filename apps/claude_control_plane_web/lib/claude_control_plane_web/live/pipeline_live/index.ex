defmodule ClaudeControlPlaneWeb.PipelineLive.Index do
  @moduledoc """
  The workspace's pipelines, with their stages and version. An empty
  workspace starts from the ready-made ones. A pipeline exports as YAML, and
  YAML imports as a new pipeline (`ClaudeControlPlane.Pipelines.Yaml`).
  """
  use ClaudeControlPlaneWeb, :live_view

  alias ClaudeControlPlane.Audit
  alias ClaudeControlPlane.Pipelines

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Pipelines", exported: nil, importing: false, import_error: nil)
     |> load_pipelines()}
  end

  @admin_events ~w(create_defaults open_import import delete)

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

  defp load_pipelines(socket),
    do:
      assign(socket, pipelines: Pipelines.list_pipelines(socket.assigns.current_scope.workspace))

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

      <div class="grid gap-4 lg:grid-cols-2">
        <.card
          :for={pipeline <- @pipelines}
          variant="outline"
          data-testid={"pipeline-#{pipeline.name}"}
        >
          <.card_content>
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <h3 class="font-semibold text-gray-900 dark:text-white">{pipeline.name}</h3>
                <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">{pipeline.description}</p>
              </div>
              <.badge
                size="sm"
                variant="outline"
                color="gray"
                label={"v#{pipeline.version}"}
                data-testid={"pipeline-version-#{pipeline.name}"}
              />
            </div>
            <ol class="mt-4 flex flex-wrap gap-2">
              <li :for={{stage, index} <- Enum.with_index(pipeline.stages)}>
                <.badge
                  size="sm"
                  variant="soft"
                  color="primary"
                  label={"#{index + 1}. #{stage.name}"}
                />
              </li>
            </ol>
            <div class="mt-4 flex justify-end gap-1">
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
        :if={@importing}
        id="import-modal"
        title="Importar pipeline"
        max_width="xl"
        on_cancel={JS.push("close_import")}
      >
        <.form for={to_form(%{"yaml" => ""}, as: "import")} id="import-form" phx-submit="import">
          <.field
            field={to_form(%{"yaml" => ""}, as: "import")[:yaml]}
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
