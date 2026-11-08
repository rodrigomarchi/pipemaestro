defmodule PipeMaestroWeb.PipelineLive.Form do
  @moduledoc """
  Creates or edits a pipeline: its name, delivery and context, and its stages.
  The pipeline is its diagram (`PipeMaestroWeb.PipelineComponents.pipeline_diagram/1`,
  over the form's draft), drawn like everywhere else; the entry or a stage
  opens its fields (`PipeMaestroWeb.PipelineLive.FormFields`) in the drawer
  (`PipeMaestroWeb.PipelineComponents.side_panel/1`), in tabs that open on
  what matters most (a stage's prompt and model), and the structure
  (insert, move, remove, run in parallel) changes on the diagram. Every field
  is rendered once: a closed drawer keeps its inputs in the page, hidden.
  Prompts are written in a Markdown editor
  (`PipeMaestroWeb.FormComponents.markdown_editor/1`).
  A new pipeline can start from an agent's proposal, and an existing one from
  an improvement the agent proposed for it (`?proposta=<job id>`,
  `PipeMaestro.Proposals`), to be reviewed and saved.
  The form's params are kept as they are typed, so moving a stage keeps
  whatever was written in it.
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
     |> assign(from_proposal: from_proposal?(params))
     |> assign(selected: if(pipeline.id, do: nil, else: :entry), tab: nil)
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
      "auto_merge" => to_string(pipeline.auto_merge),
      "merge_method" => pipeline.merge_method,
      "max_merge_fixes" => to_string(pipeline.max_merge_fixes),
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

  defp update_stages(socket, fun) do
    params = socket.assigns.params
    stages = params |> StageParams.list() |> fun.() |> StageParams.indexed()

    put_params(socket, Map.put(params, "stages", stages), socket.assigns.form.source.action)
  end

  defp count(socket), do: length(StageParams.list(socket.assigns.params))

  @impl true
  def handle_event("validate", %{"pipeline" => params}, socket),
    do: {:noreply, put_params(socket, params, :validate)}

  def handle_event("select_node", %{"node" => "entry"}, socket),
    do: {:noreply, assign(socket, selected: :entry, tab: nil)}

  def handle_event("select_node", %{"node" => index}, socket),
    do: {:noreply, assign(socket, selected: {:stage, String.to_integer(index)}, tab: nil)}

  def handle_event("select_tab", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("close_panel", _params, socket),
    do: {:noreply, assign(socket, selected: nil)}

  def handle_event("insert_stage", %{"at" => at}, socket) do
    at = String.to_integer(at)

    {:noreply,
     socket
     |> assign(selected: {:stage, at}, tab: nil)
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
        {selected, tab} = invalid_node(changeset, socket.assigns.selected, socket.assigns.tab)

        {:noreply,
         assign(socket,
           params: params,
           form: to_form(changeset),
           selected: selected,
           tab: tab
         )}
    end
  end

  # The drawer and its tab that show what kept the pipeline from saving: the
  # open drawer if it has an error, else the entry's or the first invalid
  # stage's; the open tab if it has one, else the first tab that does.
  defp invalid_node(changeset, selected, tab) do
    errors = node_errors(changeset)
    node = error_node(errors, selected)

    case Map.fetch(errors, node) do
      {:ok, fields} -> {node, error_tab(node, fields, selected, tab)}
      :error -> {node, tab}
    end
  end

  # The fields in error, by node: the entry's, and each stage's by position.
  defp node_errors(changeset) do
    # The stages the form replaced come along; only the ones it sent have a position.
    stages =
      changeset
      |> Ecto.Changeset.get_change(:stages, [])
      |> Enum.reject(&(&1.action == :replace))

    errors =
      for {stage, index} <- Enum.with_index(stages),
          not stage.valid?,
          into: %{},
          do: {{:stage, index}, Keyword.keys(stage.errors)}

    case Keyword.keys(Keyword.delete(changeset.errors, :stages)) do
      [] -> errors
      fields -> Map.put(errors, :entry, fields)
    end
  end

  defp error_node(errors, selected) do
    cond do
      Map.has_key?(errors, selected) -> selected
      Map.has_key?(errors, :entry) -> :entry
      errors != %{} -> errors |> Map.keys() |> Enum.min()
      true -> selected
    end
  end

  defp error_tab(node, fields, selected, tab) do
    tabs = node_tabs(node)
    open_tab = node == selected && Enum.find(tabs, &(elem(&1, 0) == tab))

    if open_tab && Enum.any?(fields, &(&1 in elem(open_tab, 3))),
      do: tab,
      else: tab_of(tabs, fields)
  end

  defp node_tabs(:entry), do: entry_tabs()
  defp node_tabs({:stage, _index}), do: stage_tabs()

  # The tab a node's drawer shows: the one chosen while it is open, else its first.
  defp node_tab(node, selected, tab) do
    [{first, _, _, _} | _] = tabs = node_tabs(node)
    if node == selected and Enum.any?(tabs, &(elem(&1, 0) == tab)), do: tab, else: first
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        diagram: PipelineDiagram.build(Ecto.Changeset.apply_changes(assigns.form.source))
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      pending_decisions={@pending_decisions}
      notification_center={@notification_center}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:pipelines}
      title={@page_title}
      back={
        %{
          to:
            if(@pipeline.id,
              do: ~p"/w/#{@current_scope.workspace.slug}/pipelines/#{@pipeline.id}",
              else: ~p"/w/#{@current_scope.workspace.slug}/pipelines"
            ),
          label: if(@pipeline.id, do: @pipeline.name, else: "Pipelines"),
          testid: "back-to-pipeline"
        }
      }
    >
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

      <.form for={@form} id="pipeline-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <p
          :if={@form.source.action && @form[:stages].errors != []}
          class="text-sm text-danger-600 dark:text-danger-400"
          data-testid="pipeline-stages-error"
        >
          {@form[:stages].errors |> Enum.map_join(" ", &elem(&1, 0))}
        </p>

        <.card variant="outline">
          <.card_content class="!p-0">
            <.pipeline_diagram diagram={@diagram} mode={:edit} selected={@selected} />
          </.card_content>
        </.card>

        <.side_panel
          id="pipeline-panel"
          title="Entrada e contexto"
          description="O pipeline em si: nome, entrega, teto de custo e o que vale para todas as etapas."
          open={@selected == :entry}
          testid="pipeline-panel"
        >
          <.entry_fields form={@form} tab={node_tab(:entry, @selected, @tab)} />
          <:footer>
            <.button type="submit" icon="hero-check" data-testid="pipeline-panel-save">
              Salvar
            </.button>
          </:footer>
        </.side_panel>

        <.inputs_for :let={stage} field={@form[:stages]}>
          <.side_panel
            id={"stage-panel-#{stage.index}"}
            title={"#{stage.index + 1}. #{stage_title(stage)}"}
            open={@selected == {:stage, stage.index}}
            testid={"stage-panel-#{stage.index}"}
          >
            <.stage_fields stage={stage} tab={node_tab({:stage, stage.index}, @selected, @tab)} />
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

        <div class="sticky bottom-0 z-10 -mx-1 flex justify-end rounded-xl border border-gray-200 bg-white/90 px-4 py-3 shadow-lg backdrop-blur dark:border-gray-700 dark:bg-gray-900/90">
          <.button type="submit" icon="hero-check" data-testid="pipeline-save">Salvar</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
