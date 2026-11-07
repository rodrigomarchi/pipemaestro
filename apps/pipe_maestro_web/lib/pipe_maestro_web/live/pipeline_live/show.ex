defmodule PipeMaestroWeb.PipelineLive.Show do
  @moduledoc """
  A pipeline's page, for every member of the workspace: the pipeline as a
  diagram (`PipeMaestroWeb.PipelineExplorer`): a stage opens its details in a
  side panel, and the entry the pipeline's own settings. An admin edits it
  from here (`PipeMaestroWeb.PipelineLive.Form`).
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.Pipelines
  alias PipeMaestroWeb.{Markdown, PipelineExplorer}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    pipeline = Pipelines.get_pipeline!(socket.assigns.current_scope.workspace, id)

    {:ok, assign(socket, page_title: pipeline.name, pipeline: pipeline)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:pipelines}
      title={@pipeline.name}
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/pipelines"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
          data-testid="pipeline-page-back"
        >
          Pipelines
        </.button>
        <.button
          :if={can?(@current_scope, :manage_pipelines)}
          link_type="live_redirect"
          to={~p"/w/#{@current_scope.workspace.slug}/pipelines/#{@pipeline.id}/edit"}
          size="sm"
          icon="hero-pencil-square"
          data-testid="pipeline-page-edit"
        >
          Editar
        </.button>
      </:actions>

      <div class="space-y-4">
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-gray-500 dark:text-gray-400">
          <.badge
            size="sm"
            variant="outline"
            color="gray"
            label={"v#{@pipeline.version}"}
            data-testid="pipeline-page-version"
          />
          <span :if={@pipeline.description} class="text-gray-600 dark:text-gray-300">
            {Markdown.inline_html(@pipeline.description)}
          </span>
        </div>

        <.card variant="outline">
          <.card_content class="!p-0">
            <.live_component module={PipelineExplorer} id="pipeline-explorer" pipeline={@pipeline} />
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
