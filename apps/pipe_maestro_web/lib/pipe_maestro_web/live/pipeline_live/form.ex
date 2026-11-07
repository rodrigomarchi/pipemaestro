defmodule PipeMaestroWeb.PipelineLive.Form do
  @moduledoc """
  Creates or edits a pipeline: its name, delivery and context, and its stages,
  which can be added, removed, moved and collapsed. It opens on the Diagrama
  tab (`PipeMaestroWeb.PipelineComponents.pipeline_diagram/1`, over the form's
  draft), where a node opens its fields in a side panel and the structure
  changes in place; `?view=form` is the Formulário tab, a card per stage.
  Both tabs are one form: every field (`PipeMaestroWeb.PipelineLive.FormFields`)
  is rendered once, in the frame of the tab, and a closed panel keeps its
  inputs in the page, hidden. Prompts are written in a
  Markdown editor (`PipeMaestroWeb.FormComponents.markdown_editor/1`).
  A new pipeline can start from an agent's proposal, and an existing one from
  an improvement the agent proposed for it (`?proposta=<job id>`,
  `PipeMaestro.Proposals`), to be reviewed and saved.
  The form's params are kept as they are typed, so moving a stage keeps
  whatever was written in it; a collapsed stage keeps its inputs in the page,
  hidden.
  """
  use PipeMaestroWeb, :live_view

  alias PipeMaestro.Audit
  alias PipeMaestro.Pipelines
  alias PipeMaestro.Pipelines.{Json, Pipeline, Stage}
  alias PipeMaestro.Proposals
  alias PipeMaestroWeb.PipelineDiagram
  alias PipeMaestroWeb.PipelineLive.StageParams

  import PipeMaestroWeb.PipelineComponents, only: [pipeline_diagram: 1, side_panel: 1]
  import PipeMaestroWeb.PipelineLive.FormFields

  @impl true
  def mount(params, session, socket) do
    if can?(socket.assigns.current_scope, :manage_pipelines),
      do: mount_form(params, session, socket),
      else:
        {:ok,
         socket
         |> put_flash(:error, "Só admins do workspace mudam os pipelines.")
         |> push_navigate(to: denied_path(socket.assigns.current_scope.workspace, params))}
  end

  defp mount_form(params, _session, socket) do
    workspace = socket.assigns.current_scope.workspace

    pipeline =
      case socket.assigns.live_action do
        :edit -> Pipelines.get_pipeline!(workspace, params["id"])
        :new -> %Pipeline{workspace_id: workspace.id}
      end

    {:ok,
     socket
     |> assign(page_title: page_title(socket.assigns.live_action), pipeline: pipeline)
     |> assign(collapsed: MapSet.new(), from_proposal: from_proposal?(params))
     |> assign(selected: if(pipeline.id, do: nil, else: :entry))
     |> put_params(starting_params(pipeline, params, workspace), nil)}
  end

  # Someone who cannot edit a pipeline still sees it.
  defp denied_path(workspace, %{"id" => id}), do: ~p"/w/#{workspace.slug}/pipelines/#{id}"
  defp denied_path(workspace, _params), do: ~p"/w/#{workspace.slug}/pipelines"

  defp from_proposal?(params), do: is_binary(params["proposta"])

  defp proposal_fits?("pipeline", %Pipeline{id: nil}, _job), do: true

  defp proposal_fits?("improve", %Pipeline{id: id}, job) when is_binary(id),
    do: Proposals.input(job)["pipeline_id"] == id

  defp proposal_fits?(_kind, _pipeline, _job), do: false

  # A new pipeline starts from a pipeline proposal, and an existing one from
  # an improvement of it, when one is named; otherwise from what it has.
  defp starting_params(pipeline, %{"proposta" => job_id}, workspace) when is_binary(job_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(job_id),
         job = Proposals.get_proposal!(workspace, job_id),
         true <- proposal_fits?(Proposals.kind(job), pipeline, job),
         {:ok, result} <- Proposals.result(job) do
      proposal_params(result.pipeline)
    else
      _no_proposal -> initial_params(pipeline)
    end
  end

  defp starting_params(pipeline, _params, _workspace), do: initial_params(pipeline)

  # A proposal's attributes (`PipeMaestro.Pipelines.Yaml.from_map/1`) as the
  # form's params: stages indexed, every value text.
  defp proposal_params(attrs) do
    stages =
      attrs
      |> Map.get("stages", [])
      |> Enum.map(fn stage -> Map.merge(StageParams.new(), Map.new(stage, &text_param/1)) end)
      |> StageParams.indexed()

    attrs
    |> Map.delete("stages")
    |> Map.new(&text_param/1)
    |> Map.put_new("description", "")
    |> Map.put("stages", stages)
  end

  defp text_param({key, nil}), do: {key, ""}
  defp text_param({key, value}) when is_binary(value), do: {key, value}
  defp text_param({key, value}), do: {key, to_string(value)}

  defp page_title(:new), do: "Novo pipeline"
  defp page_title(:edit), do: "Editar pipeline"

  defp initial_params(%Pipeline{id: nil}),
    do: %{"name" => "", "description" => "", "stages" => %{"0" => StageParams.new()}}

  defp initial_params(%Pipeline{} = pipeline) do
    %{
      "name" => pipeline.name,
      "description" => pipeline.description || "",
      "system_prompt" => pipeline.system_prompt || "",
      "delivery" => pipeline.delivery,
      "max_task_cost_usd" =>
        if(pipeline.max_task_cost_usd, do: to_string(pipeline.max_task_cost_usd), else: ""),
      "mcp_config_json" => Pipeline.mcp_config_json(pipeline),
      "agents_json" => Pipeline.agents_json(pipeline),
      "stages" => pipeline.stages |> Enum.map(&stage_params/1) |> StageParams.indexed()
    }
  end

  defp stage_params(%Stage{} = stage) do
    %{
      "key" => stage.key,
      "name" => stage.name,
      "prompt" => stage.prompt,
      "max_attempts" => to_string(stage.max_attempts),
      "model" => stage.model || "",
      "max_budget_usd" => if(stage.max_budget_usd, do: to_string(stage.max_budget_usd), else: ""),
      "timeout_minutes" => to_string(stage.timeout_minutes),
      "gates_text" => Stage.gates_text(stage),
      "rules_text" => Stage.rules_text(stage),
      "agent" => stage.agent || "",
      "group" => stage.group || "",
      "context" => stage.context,
      "output_schema_json" =>
        if(stage.output_schema, do: Json.pretty(stage.output_schema), else: "")
    }
  end

  defp put_params(socket, params, action) do
    changeset =
      socket.assigns.pipeline
      |> Pipelines.change_pipeline(params)
      |> Map.put(:action, action)

    assign(socket, params: params, form: to_form(changeset))
  end

  # Stages are known by their position, which this changes: whatever was
  # collapsed opens again.
  defp update_stages(socket, fun) do
    params = socket.assigns.params
    stages = params |> StageParams.list() |> fun.() |> StageParams.indexed()

    socket
    |> assign(collapsed: MapSet.new())
    |> put_params(Map.put(params, "stages", stages), socket.assigns.form.source.action)
  end

  defp count(socket), do: length(StageParams.list(socket.assigns.params))

  @impl true
  def handle_params(params, _uri, socket),
    do:
      {:noreply, assign(socket, view: if(params["view"] == "form", do: "form", else: "diagram"))}

  @impl true
  def handle_event("validate", %{"pipeline" => params}, socket),
    do: {:noreply, put_params(socket, params, :validate)}

  def handle_event("select_node", %{"node" => "entry"}, socket),
    do: {:noreply, assign(socket, selected: :entry)}

  def handle_event("select_node", %{"node" => index}, socket),
    do: {:noreply, assign(socket, selected: {:stage, String.to_integer(index)})}

  def handle_event("close_panel", _params, socket),
    do: {:noreply, assign(socket, selected: nil)}

  def handle_event("toggle_stage", %{"index" => index}, socket) do
    index = String.to_integer(index)
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, index),
        do: MapSet.delete(collapsed, index),
        else: MapSet.put(collapsed, index)

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  def handle_event("add_stage", _params, socket),
    do: {:noreply, update_stages(socket, &(&1 ++ [StageParams.new()]))}

  def handle_event("insert_stage", %{"at" => at}, socket) do
    at = String.to_integer(at)

    {:noreply,
     socket
     |> assign(selected: {:stage, at})
     |> update_stages(&StageParams.insert_at(&1, at))}
  end

  def handle_event("remove_stage", %{"index" => index}, socket) do
    {:noreply,
     socket
     |> assign(selected: nil)
     |> update_stages(&StageParams.remove(&1, String.to_integer(index)))}
  end

  def handle_event("move_stage", %{"index" => index, "to" => to}, socket) do
    {from, to} = {String.to_integer(index), String.to_integer(to)}

    selected =
      if socket.assigns.selected == {:stage, from} and to in 0..(count(socket) - 1)//1,
        do: {:stage, to},
        else: socket.assigns.selected

    {:noreply,
     socket
     |> assign(selected: selected)
     |> update_stages(&StageParams.move(&1, from, to))}
  end

  def handle_event("join_group", %{"index" => index}, socket),
    do: {:noreply, update_stages(socket, &StageParams.join_group(&1, String.to_integer(index)))}

  def handle_event("leave_group", %{"index" => index}, socket),
    do: {:noreply, update_stages(socket, &StageParams.leave_group(&1, String.to_integer(index)))}

  def handle_event("save", %{"pipeline" => params}, socket) do
    workspace = socket.assigns.current_scope.workspace

    result =
      case socket.assigns.live_action do
        :new -> Pipelines.create_pipeline(workspace, params)
        :edit -> Pipelines.update_pipeline(socket.assigns.pipeline, params)
      end

    case result do
      {:ok, pipeline} ->
        Audit.record(workspace, socket.assigns.current_scope.user, "pipeline.saved", pipeline, %{
          "version" => pipeline.version
        })

        {:noreply,
         socket
         |> put_flash(:info, "Pipeline #{pipeline.name} salvo (v#{pipeline.version}).")
         |> push_navigate(to: ~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, params: params, form: to_form(changeset))}
    end
  end

  defp tab_path(workspace, %Pipeline{id: nil}, view),
    do: tab_query(~p"/w/#{workspace.slug}/pipelines/new", view)

  defp tab_path(workspace, pipeline, view),
    do: tab_query(~p"/w/#{workspace.slug}/pipelines/#{pipeline.id}/edit", view)

  defp tab_query(path, "form"), do: path <> "?view=form"
  defp tab_query(path, _diagram), do: path

  defp tabs,
    do: [{"diagram", "Diagrama", "hero-share"}, {"form", "Formulário", "hero-queue-list"}]

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        diagram: PipelineDiagram.build(Ecto.Changeset.apply_changes(assigns.form.source)),
        count: length(StageParams.list(assigns.params))
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:pipelines}
      title={@page_title}
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={
            if @pipeline.id,
              do: ~p"/w/#{@current_scope.workspace.slug}/pipelines/#{@pipeline.id}",
              else: ~p"/w/#{@current_scope.workspace.slug}/pipelines"
          }
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
        >
          {if @pipeline.id, do: "Voltar", else: "Pipelines"}
        </.button>
      </:actions>

      <.tabs variant="underline" class="mb-6 overflow-x-auto" data-testid="pipeline-view-tabs">
        <.tab
          :for={{id, label, icon} <- tabs()}
          link_type="live_patch"
          to={tab_path(@current_scope.workspace, @pipeline, id)}
          is_active={@view == id}
          variant="underline"
          aria-current={@view == id && "page"}
          data-testid={"pipeline-view-#{id}"}
        >
          <.icon name={icon} class="mr-1.5 size-4" /> {label}
        </.tab>
      </.tabs>

      <.alert
        :if={@from_proposal}
        color="info"
        class="mb-6"
        with_icon
        data-testid="pipeline-from-proposal"
      >
        Este é o pipeline que o agente propôs. Revise as etapas, ajuste o que quiser e salve {if @pipeline.id,
          do: "(vira a versão #{@pipeline.version + 1})"}.
      </.alert>

      <.form for={@form} id="pipeline-form" phx-change="validate" phx-submit="save" class="space-y-6">
        <.card :if={@view == "diagram"} variant="outline">
          <.card_content class="!p-0">
            <.pipeline_diagram diagram={@diagram} mode={:edit} selected={@selected} />
          </.card_content>
        </.card>

        <div :if={@view == "form"} class="grid gap-6 xl:grid-cols-3">
          <.card variant="outline" class="xl:col-span-2">
            <.card_content><.identity_fields form={@form} /></.card_content>
          </.card>
          <.card variant="outline">
            <.card_content><.execution_fields form={@form} /></.card_content>
          </.card>
          <.card variant="outline" class="xl:col-span-3">
            <.card_content><.context_fields form={@form} /></.card_content>
          </.card>
        </div>

        <.side_panel
          :if={@view == "diagram"}
          id="pipeline-panel"
          title="Entrada e contexto"
          description="O pipeline em si: nome, entrega, teto de custo e o que vale para todas as etapas."
          open={@selected == :entry}
          testid="pipeline-panel"
        >
          <div class="space-y-8">
            <div><.identity_fields form={@form} /></div>
            <div><.execution_fields form={@form} /></div>
            <div><.context_fields form={@form} /></div>
          </div>
          <:footer>
            <.button type="submit" icon="hero-check" data-testid="pipeline-panel-save">
              Salvar
            </.button>
          </:footer>
        </.side_panel>

        <div :if={@view == "form"} class="flex items-center justify-between gap-2">
          <h2 class="flex items-center gap-2 text-lg font-semibold text-gray-900 dark:text-white">
            <.icon name="hero-queue-list" class="size-5 text-primary-500 dark:text-primary-400" />
            Etapas
          </h2>
        </div>
        <p
          :if={@form.source.action && @form[:stages].errors != []}
          class="text-sm text-danger-600 dark:text-danger-400"
          data-testid="pipeline-stages-error"
        >
          {@form[:stages].errors |> Enum.map_join(" ", &elem(&1, 0))}
        </p>

        <div class={@view == "form" && "space-y-4"}>
          <.inputs_for :let={stage} field={@form[:stages]}>
            <.card :if={@view == "form"} variant="outline" data-testid={"stage-card-#{stage.index}"}>
              <.card_content>
                <.stage_header
                  stage={stage}
                  count={@count}
                  collapsed={MapSet.member?(@collapsed, stage.index)}
                />
                <div class="mt-5">
                  <.stage_fields stage={stage} hidden={MapSet.member?(@collapsed, stage.index)} />
                </div>
              </.card_content>
            </.card>
            <.side_panel
              :if={@view == "diagram"}
              id={"stage-panel-#{stage.index}"}
              title={"#{stage.index + 1}. #{stage_title(stage)}"}
              open={@selected == {:stage, stage.index}}
              testid={"stage-panel-#{stage.index}"}
            >
              <.stage_fields stage={stage} />
              <:footer>
                <.button
                  type="submit"
                  icon="hero-check"
                  data-testid={"stage-panel-#{stage.index}-save"}
                >
                  Salvar
                </.button>
              </:footer>
            </.side_panel>
          </.inputs_for>
        </div>

        <div class="sticky bottom-0 z-10 -mx-1 flex justify-between gap-2 rounded-xl border border-gray-200 bg-white/90 px-4 py-3 shadow-lg backdrop-blur dark:border-gray-700 dark:bg-gray-900/90">
          <.button
            type="button"
            variant="outline"
            icon="hero-plus"
            phx-click="add_stage"
            data-testid="stage-add"
          >
            Adicionar etapa
          </.button>
          <.button type="submit" icon="hero-check" data-testid="pipeline-save">Salvar</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
