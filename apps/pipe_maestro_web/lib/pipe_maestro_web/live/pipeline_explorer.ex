defmodule PipeMaestroWeb.PipelineExplorer do
  @moduledoc """
  A pipeline to explore, wherever a page shows one: its diagram
  (`PipeMaestroWeb.PipelineComponents.pipeline_diagram/1`, with the layers in
  `opts`, `PipeMaestroWeb.PipelineDiagram.build/2`), where a stage opens its
  details in a side panel and the entry the pipeline's own settings, each in
  tabs that open on what matters most. The component keeps which node and tab
  are open, so the page holds no state for them.
  """
  use PipeMaestroWeb, :live_component

  import PipeMaestroWeb.PipelineComponents

  alias PipeMaestroWeb.PipelineDiagram

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, selected: nil, tab: nil, opts: [], testid: "pipeline")}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     assign(socket, diagram: PipelineDiagram.build(socket.assigns.pipeline, socket.assigns.opts))}
  end

  @impl true
  def handle_event("select_node", %{"node" => "entry"}, socket),
    do: {:noreply, assign(socket, selected: :entry, tab: nil)}

  def handle_event("select_node", %{"node" => index}, socket),
    do: {:noreply, assign(socket, selected: {:stage, String.to_integer(index)}, tab: nil)}

  def handle_event("select_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("close_panel", _params, socket),
    do: {:noreply, assign(socket, selected: nil)}

  defp panel_title(_pipeline, :entry), do: "Entrada e contexto"
  defp panel_title(pipeline, {:stage, index}), do: Enum.at(pipeline.stages, index).name

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.pipeline_diagram
        diagram={@diagram}
        selected={@selected}
        target={@myself}
        testid={"#{@testid}-diagram"}
      />
      <.side_panel
        :if={@selected}
        id={"#{@id}-panel"}
        title={panel_title(@pipeline, @selected)}
        open
        target={@myself}
        testid={"#{@testid}-panel"}
      >
        <.pipeline_summary
          :if={@selected == :entry}
          pipeline={@pipeline}
          tab={@tab}
          target={@myself}
        />
        <.stage_details
          :if={match?({:stage, _}, @selected)}
          stage={Enum.at(@pipeline.stages, elem(@selected, 1))}
          tab={@tab}
          target={@myself}
        />
      </.side_panel>
    </div>
    """
  end
end
