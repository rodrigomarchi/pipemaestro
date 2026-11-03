defmodule ClaudeControlPlaneWeb.PipelineLive.Form do
  @moduledoc """
  Creates or edits a pipeline: its name and its stages, which can be added,
  removed and moved. The form's params are kept as they are typed, so moving
  a stage keeps whatever was written in it.
  """
  use ClaudeControlPlaneWeb, :live_view

  alias ClaudeControlPlane.Audit
  alias ClaudeControlPlane.Pipelines
  alias ClaudeControlPlane.Pipelines.{Pipeline, Prompt, Stage}

  @impl true
  def mount(params, session, socket) do
    if can?(socket.assigns.current_scope, :manage_pipelines),
      do: mount_form(params, session, socket),
      else:
        {:ok,
         socket
         |> put_flash(:error, "Só admins do workspace mudam os pipelines.")
         |> push_navigate(to: ~p"/w/#{socket.assigns.current_scope.workspace.slug}/pipelines")}
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
     |> put_params(initial_params(pipeline), nil)}
  end

  defp page_title(:new), do: "Novo pipeline"
  defp page_title(:edit), do: "Editar pipeline"

  defp initial_params(%Pipeline{id: nil}),
    do: %{"name" => "", "description" => "", "stages" => %{"0" => new_stage()}}

  defp initial_params(%Pipeline{} = pipeline) do
    %{
      "name" => pipeline.name,
      "description" => pipeline.description || "",
      "system_prompt" => pipeline.system_prompt || "",
      "max_task_cost_usd" =>
        if(pipeline.max_task_cost_usd, do: to_string(pipeline.max_task_cost_usd), else: ""),
      "mcp_config_json" => Pipeline.mcp_config_json(pipeline),
      "agents_json" => Pipeline.agents_json(pipeline),
      "stages" => pipeline.stages |> Enum.map(&stage_params/1) |> to_indexed()
    }
  end

  defp stage_params(%Stage{} = stage) do
    %{
      "key" => stage.key,
      "name" => stage.name,
      "prompt" => stage.prompt,
      "max_attempts" => to_string(stage.max_attempts),
      "pause_after" => to_string(stage.pause_after),
      "model" => stage.model || "",
      "max_budget_usd" => if(stage.max_budget_usd, do: to_string(stage.max_budget_usd), else: ""),
      "timeout_minutes" => to_string(stage.timeout_minutes),
      "gates_text" => Stage.gates_text(stage),
      "rules_text" => Stage.rules_text(stage),
      "permission_profile" => stage.permission_profile,
      "agent" => stage.agent || "",
      "allowed_tools_text" => Stage.allowed_tools_text(stage),
      "denied_tools_text" => Stage.denied_tools_text(stage),
      "output_schema_json" =>
        if(stage.output_schema, do: Jason.encode!(stage.output_schema, pretty: true), else: "")
    }
  end

  defp permission_options do
    [
      {"Tudo (sem restrição)", "total"},
      {"Editar arquivos e rodar o que for liberado", "edicao"},
      {"Só ler e escrever o próprio artefato", "leitura"}
    ]
  end

  defp new_stage, do: %{"name" => "", "prompt" => "", "max_attempts" => "2"}

  defp to_indexed(stages),
    do: stages |> Enum.with_index() |> Map.new(fn {stage, i} -> {Integer.to_string(i), stage} end)

  defp stages_list(params) do
    (params["stages"] || %{})
    |> Enum.sort_by(fn {index, _stage} -> String.to_integer(index) end)
    |> Enum.map(&elem(&1, 1))
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
    stages = params |> stages_list() |> fun.() |> to_indexed()
    put_params(socket, Map.put(params, "stages", stages), socket.assigns.form.source.action)
  end

  @impl true
  def handle_event("validate", %{"pipeline" => params}, socket),
    do: {:noreply, put_params(socket, params, :validate)}

  def handle_event("add_stage", _params, socket),
    do: {:noreply, update_stages(socket, &(&1 ++ [new_stage()]))}

  def handle_event("remove_stage", %{"index" => index}, socket),
    do: {:noreply, update_stages(socket, &List.delete_at(&1, String.to_integer(index)))}

  def handle_event("move_stage", %{"index" => index, "to" => to}, socket) do
    {from, to} = {String.to_integer(index), String.to_integer(to)}

    {:noreply,
     update_stages(socket, fn stages ->
       if to in 0..(length(stages) - 1)//1 do
         {stage, rest} = List.pop_at(stages, from)
         List.insert_at(rest, to, stage)
       else
         stages
       end
     end)}
  end

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
         |> push_navigate(to: ~p"/w/#{workspace.slug}/pipelines")}

      {:error, changeset} ->
        {:noreply, assign(socket, params: params, form: to_form(changeset))}
    end
  end

  defp model_options, do: [{"Padrão do CLI", ""} | Enum.map(Stage.models(), &{&1, &1})]

  defp variables_help do
    Prompt.variables() |> Enum.map_join(", ", &"{{#{&1}}}")
  end

  @impl true
  def render(assigns) do
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
          to={~p"/w/#{@current_scope.workspace.slug}/pipelines"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
        >
          Pipelines
        </.button>
      </:actions>

      <.form for={@form} id="pipeline-form" phx-change="validate" phx-submit="save" class="space-y-6">
        <.card variant="outline">
          <.card_content>
            <.field field={@form[:name]} label="Nome" data-testid="pipeline-name" />
            <.field
              field={@form[:description]}
              type="textarea"
              rows="2"
              label="Descrição"
              data-testid="pipeline-description"
            />
            <.field
              field={@form[:max_task_cost_usd]}
              type="number"
              step="0.01"
              min="0"
              label="Orçamento por tarefa (US$, opcional)"
              help_text="Passou disso, a tarefa pausa para decisão depois da etapa."
              data-testid="pipeline-max-cost"
            />
            <details class="mt-2">
              <summary class="cursor-pointer text-sm font-medium text-gray-600 dark:text-gray-300">
                Contexto do pipeline: instruções de sistema, servidores MCP e agentes
              </summary>
              <div class="mt-3 space-y-4">
                <.field
                  field={@form[:system_prompt]}
                  type="textarea"
                  rows="3"
                  label="Instruções de sistema (somadas às do agente em todas as etapas)"
                  data-testid="pipeline-system-prompt"
                />
                <.field
                  field={@form[:mcp_config_json]}
                  type="textarea"
                  rows="4"
                  label="Servidores MCP (JSON com mcpServers)"
                  placeholder={~s({"mcpServers": {"grafana": {"command": "mcp-grafana"}}})}
                  help_text="Não guarde segredos aqui: use variáveis de ambiente do runner."
                  data-testid="pipeline-mcp-config"
                />
                <.field
                  field={@form[:agents_json]}
                  type="textarea"
                  rows="4"
                  label="Agentes (JSON por nome)"
                  placeholder={
                    ~s({"revisor": {"description": "Revisa o diff", "prompt": "Revise..."}})
                  }
                  data-testid="pipeline-agents"
                />
              </div>
            </details>
            <p class="text-sm text-gray-500 dark:text-gray-400">
              Cada etapa roda com contexto novo, lê os artefatos das anteriores e responde com
              status (ok ou bloqueado) e resumo. Variáveis do prompt: <code>{variables_help()}</code>
            </p>
            <p
              :if={@form.source.action && @form[:stages].errors != []}
              class="mt-2 text-sm text-danger-600 dark:text-danger-400"
              data-testid="pipeline-stages-error"
            >
              {@form[:stages].errors |> Enum.map_join(" ", &elem(&1, 0))}
            </p>
          </.card_content>
        </.card>

        <.inputs_for :let={stage} field={@form[:stages]}>
          <.card variant="outline" data-testid={"stage-card-#{stage.index}"}>
            <.card_content>
              <div class="mb-4 flex items-center justify-between gap-2">
                <h3 class="font-semibold text-gray-900 dark:text-white">Etapa {stage.index + 1}</h3>
                <div class="flex gap-1">
                  <.button
                    type="button"
                    size="xs"
                    variant="ghost"
                    color="gray"
                    icon="hero-arrow-up"
                    phx-click="move_stage"
                    phx-value-index={stage.index}
                    phx-value-to={stage.index - 1}
                    data-testid={"stage-up-#{stage.index}"}
                  >
                    <span class="sr-only">Subir</span>
                  </.button>
                  <.button
                    type="button"
                    size="xs"
                    variant="ghost"
                    color="gray"
                    icon="hero-arrow-down"
                    phx-click="move_stage"
                    phx-value-index={stage.index}
                    phx-value-to={stage.index + 1}
                    data-testid={"stage-down-#{stage.index}"}
                  >
                    <span class="sr-only">Descer</span>
                  </.button>
                  <.button
                    type="button"
                    size="xs"
                    variant="ghost"
                    color="danger"
                    icon="hero-trash"
                    phx-click="remove_stage"
                    phx-value-index={stage.index}
                    data-testid={"stage-remove-#{stage.index}"}
                  >
                    Remover
                  </.button>
                </div>
              </div>

              <div class="grid gap-4 sm:grid-cols-2">
                <.field field={stage[:name]} label="Nome" data-testid={"stage-name-#{stage.index}"} />
                <.field
                  field={stage[:key]}
                  label="Chave"
                  help_text="Nome do artefato; em branco, vem do nome."
                  data-testid={"stage-key-#{stage.index}"}
                />
              </div>
              <.field
                field={stage[:prompt]}
                type="textarea"
                rows="6"
                label="Prompt"
                data-testid={"stage-prompt-#{stage.index}"}
              />
              <div class="grid gap-4 sm:grid-cols-4">
                <.field
                  field={stage[:max_attempts]}
                  type="number"
                  min="1"
                  max="5"
                  label="Tentativas"
                  data-testid={"stage-attempts-#{stage.index}"}
                />
                <.field
                  field={stage[:model]}
                  type="select"
                  label="Modelo"
                  options={model_options()}
                  data-testid={"stage-model-#{stage.index}"}
                />
                <.field
                  field={stage[:max_budget_usd]}
                  type="number"
                  step="0.01"
                  min="0"
                  label="Orçamento (US$)"
                  data-testid={"stage-budget-#{stage.index}"}
                />
                <.field
                  field={stage[:timeout_minutes]}
                  type="number"
                  min="1"
                  max="1440"
                  label="Tempo máximo (min)"
                  data-testid={"stage-timeout-#{stage.index}"}
                />
              </div>
              <.field
                field={stage[:pause_after]}
                type="checkbox"
                label="Pedir aprovação humana ao terminar"
                data-testid={"stage-pause-#{stage.index}"}
              />
              <div class="grid gap-4 sm:grid-cols-2">
                <.field
                  field={stage[:gates_text]}
                  type="textarea"
                  rows="3"
                  label="Gates (comandos depois da etapa)"
                  placeholder="{{projeto.teste}}\n! mix test test/repro_test.exs"
                  help_text="Um por linha; ! na frente quando o comando deve falhar. Um gate não atendido reprova a tentativa."
                  data-testid={"stage-gates-#{stage.index}"}
                />
                <.field
                  field={stage[:rules_text]}
                  type="textarea"
                  rows="3"
                  label="Pausar para decisão quando"
                  placeholder="bem_definida == false"
                  help_text="Um por linha: campo == valor ou campo != valor, sobre a saída estruturada."
                  data-testid={"stage-rules-#{stage.index}"}
                />
              </div>
              <.field
                field={stage[:agent]}
                label="Rodar como o agente (opcional)"
                placeholder="revisor"
                help_text="Um agente do repositório (.claude/agents) ou do pipeline."
                data-testid={"stage-agent-#{stage.index}"}
              />
              <div class="grid gap-4 sm:grid-cols-3">
                <.field
                  field={stage[:permission_profile]}
                  type="select"
                  label="O agente pode"
                  options={permission_options()}
                  data-testid={"stage-permission-#{stage.index}"}
                />
                <.field
                  field={stage[:allowed_tools_text]}
                  type="textarea"
                  rows="2"
                  label="Liberar também"
                  placeholder="Bash(git log:*)"
                  help_text="Uma regra por linha. Os comandos de teste e lint do projeto já vêm liberados."
                  data-testid={"stage-allowed-#{stage.index}"}
                />
                <.field
                  field={stage[:denied_tools_text]}
                  type="textarea"
                  rows="2"
                  label="Negar"
                  placeholder="WebFetch"
                  data-testid={"stage-denied-#{stage.index}"}
                />
              </div>
              <details class="mt-2">
                <summary class="cursor-pointer text-sm font-medium text-gray-600 dark:text-gray-300">
                  Campos extras da saída estruturada (JSON Schema)
                </summary>
                <div class="mt-3">
                  <.field
                    field={stage[:output_schema_json]}
                    type="textarea"
                    rows="5"
                    label="Schema"
                    placeholder={
                      ~s({"type": "object", "properties": {"arquivos": {"type": "array", "items": {"type": "string"}}}})
                    }
                    data-testid={"stage-schema-#{stage.index}"}
                  />
                </div>
              </details>
            </.card_content>
          </.card>
        </.inputs_for>

        <div class="flex justify-between gap-2">
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
