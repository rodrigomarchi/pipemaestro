defmodule ClaudeControlPlaneWeb.PipelineLive.Index do
  @moduledoc """
  The workspace's pipelines, with their stages and version. An empty
  workspace starts from the ready-made ones.
  """
  use ClaudeControlPlaneWeb, :live_view

  alias ClaudeControlPlane.Pipelines

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Pipelines") |> load_pipelines()}
  end

  @impl true
  def handle_event("create_defaults", _params, socket) do
    created = Pipelines.create_defaults(socket.assigns.current_scope.workspace)

    {:noreply,
     socket
     |> put_flash(:info, "#{length(created)} pipeline(s) padrão criado(s).")
     |> load_pipelines()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    pipeline = Pipelines.get_pipeline!(socket.assigns.current_scope.workspace, id)
    {:ok, _} = Pipelines.delete_pipeline(pipeline)

    {:noreply,
     socket
     |> put_flash(:info, "Pipeline #{pipeline.name} removido.")
     |> load_pipelines()}
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
          size="sm"
          variant="outline"
          icon="hero-sparkles"
          phx-click="create_defaults"
          data-testid="create-default-pipelines"
        >
          Criar pipelines padrão
        </.button>
        <.button
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
            description="Comece pelos pipelines padrão (Prompt único e Correção de bug) e ajuste os prompts ao seu time."
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
    </Layouts.app>
    """
  end
end
