defmodule PipeMaestroWeb.PipelineLive.Form do
  @moduledoc """
  Creates or edits a pipeline: its name, delivery and context, and its stages,
  which can be added, removed, moved and collapsed. Prompts are written in a
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
  alias PipeMaestro.Pipelines.{Json, Pipeline, Prompt, Stage}
  alias PipeMaestro.Proposals

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
     |> assign(collapsed: MapSet.new(), from_proposal: from_proposal?(params))
     |> put_params(starting_params(pipeline, params, workspace), nil)}
  end

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
      |> Enum.map(fn stage -> Map.merge(new_stage(), Map.new(stage, &text_param/1)) end)
      |> to_indexed()

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
    do: %{"name" => "", "description" => "", "stages" => %{"0" => new_stage()}}

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
      "stages" => pipeline.stages |> Enum.map(&stage_params/1) |> to_indexed()
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
      "output_schema_json" =>
        if(stage.output_schema, do: Json.pretty(stage.output_schema), else: "")
    }
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

  # Stages are known by their position, which this changes: whatever was
  # collapsed opens again.
  defp update_stages(socket, fun) do
    params = socket.assigns.params
    stages = params |> stages_list() |> fun.() |> to_indexed()

    socket
    |> assign(collapsed: MapSet.new())
    |> put_params(Map.put(params, "stages", stages), socket.assigns.form.source.action)
  end

  @impl true
  def handle_event("validate", %{"pipeline" => params}, socket),
    do: {:noreply, put_params(socket, params, :validate)}

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

  @deliveries [
    {"none", "Nenhuma: os prompts decidem", "hero-no-symbol",
     "O runner não faz commit; o que acontece com o código fica a cargo dos prompts."},
    {"commit", "Um commit por etapa", "hero-check-badge",
     "Cada etapa que passa vira um commit no branch da tarefa."},
    {"pr", "Commit, push e PR em rascunho (pronto na última etapa)", "hero-rocket-launch",
     "Cada etapa faz commit e push; o PR abre em rascunho e fica pronto na última etapa. Usa o gh de quem roda o runner."}
  ]

  defp delivery_options, do: Enum.map(@deliveries, fn {value, label, _, _} -> {label, value} end)

  defp delivery(value),
    do: Enum.find(@deliveries, hd(@deliveries), fn {key, _, _, _} -> key == value end)

  defp stage_id(index), do: "stage-#{index}-prompt"

  # What a collapsed stage still says about itself.
  defp stage_chips(stage) do
    gates = count_lines(stage[:gates_text].value)
    rules = count_lines(stage[:rules_text].value)

    [
      {"hero-sparkles", model_label(stage[:model].value)},
      {"hero-arrow-path", plural(stage[:max_attempts].value, "tentativa", "tentativas")},
      {"hero-clock", "#{stage[:timeout_minutes].value || 60} min"},
      gates > 0 && {"hero-shield-check", plural(gates, "gate", "gates")},
      rules > 0 && {"hero-hand-raised", plural(rules, "regra de ajuda", "regras de ajuda")},
      present(stage[:group].value) && {"hero-squares-2x2", "grupo #{stage[:group].value}"},
      present(stage[:agent].value) && {"hero-user-circle", stage[:agent].value}
    ]
    |> Enum.filter(& &1)
  end

  defp plural(count, one, many) do
    if to_string(count) == "1", do: "1 #{one}", else: "#{count} #{many}"
  end

  defp model_label(model) when model in [nil, ""], do: "modelo padrão"
  defp model_label(model), do: model

  defp count_lines(nil), do: 0

  defp count_lines(text),
    do: text |> to_string() |> String.split("\n") |> Enum.count(&(String.trim(&1) != ""))

  defp present(value), do: value not in [nil, ""] and String.trim(to_string(value)) != ""

  # A multi-line placeholder: in the template, the formatter would make it literal.
  defp gates_placeholder, do: "{{projeto.teste}}\n! mix test test/repro_test.exs"

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
        <div class="grid gap-6 xl:grid-cols-3">
          <.card variant="outline" class="xl:col-span-2">
            <.card_content>
              <.section_heading
                icon="hero-identification"
                title="Identificação"
                description="Como o pipeline aparece na lista e ao criar uma tarefa."
              />
              <.icon_field
                field={@form[:name]}
                icon="hero-tag"
                label="Nome"
                data-testid="pipeline-name"
              />
              <.icon_field
                field={@form[:description]}
                icon="hero-bars-3-bottom-left"
                type="textarea"
                rows="2"
                label="Descrição"
                no_margin
                data-testid="pipeline-description"
              />
            </.card_content>
          </.card>

          <.card variant="outline">
            <.card_content>
              <.section_heading
                icon="hero-rocket-launch"
                title="Execução"
                description="Um teto de custo, se quiser, e o que vira do código."
              />
              <.icon_field
                field={@form[:max_task_cost_usd]}
                icon="hero-banknotes"
                type="number"
                step="0.01"
                min="0"
                label="Teto de custo por tarefa (US$, opcional)"
                help_text="Vazio é sem limite. Com um valor, a tarefa para e pede uma decisão ao passar dele."
                data-testid="pipeline-max-cost"
              />
              <.icon_field
                field={@form[:delivery]}
                icon="hero-truck"
                type="select"
                label="Entrega (num diretório com git)"
                options={delivery_options()}
                no_margin
                data-testid="pipeline-delivery"
              />
              <p
                class="mt-2 flex gap-2 text-sm text-gray-500 dark:text-gray-400"
                data-testid="pipeline-delivery-help"
              >
                <.icon
                  name={elem(delivery(@form[:delivery].value), 2)}
                  class="mt-0.5 size-4 shrink-0 text-primary-500"
                />
                {elem(delivery(@form[:delivery].value), 3)}
              </p>
            </.card_content>
          </.card>
        </div>

        <.card variant="outline">
          <.card_content>
            <.section_heading
              icon="hero-cpu-chip"
              title="Contexto do pipeline"
              description="Vale para todas as etapas. Cada etapa roda com contexto novo, lê os artefatos das anteriores e responde com status (ok ou bloqueado) e resumo; ela segue sozinha para a próxima e só para quando precisa de ajuda."
            />
            <.markdown_editor
              id="pipeline-system-prompt"
              field={@form[:system_prompt]}
              label="Instruções de sistema"
              icon="hero-command-line"
              testid="pipeline-system-prompt"
              rows={4}
              help_text="Somadas às do agente em todas as etapas."
            />
            <details class="group mt-2">
              <summary class="flex cursor-pointer list-none items-center gap-2 text-sm font-medium text-gray-600 dark:text-gray-300">
                <.icon name="hero-chevron-right" class="size-4 transition group-open:rotate-90" />
                <.icon name="hero-puzzle-piece" class="size-4" /> Servidores MCP e agentes
              </summary>
              <div class="mt-3 grid gap-4 lg:grid-cols-2">
                <.icon_field
                  field={@form[:mcp_config_json]}
                  icon="hero-server-stack"
                  type="textarea"
                  rows="5"
                  label="Servidores MCP (JSON com mcpServers)"
                  placeholder={~s({"mcpServers": {"grafana": {"command": "mcp-grafana"}}})}
                  help_text="Não guarde segredos aqui: use variáveis de ambiente do runner."
                  class="font-mono text-sm"
                  data-testid="pipeline-mcp-config"
                />
                <.icon_field
                  field={@form[:agents_json]}
                  icon="hero-user-group"
                  type="textarea"
                  rows="5"
                  label="Agentes (JSON por nome)"
                  placeholder={
                    ~s({"revisor": {"description": "Revisa o diff", "prompt": "Revise..."}})
                  }
                  class="font-mono text-sm"
                  data-testid="pipeline-agents"
                />
              </div>
            </details>
          </.card_content>
        </.card>

        <div class="flex items-center justify-between gap-2">
          <h2 class="flex items-center gap-2 text-lg font-semibold text-gray-900 dark:text-white">
            <.icon name="hero-queue-list" class="size-5 text-primary-500 dark:text-primary-400" />
            Etapas
          </h2>
          <p
            :if={@form.source.action && @form[:stages].errors != []}
            class="text-sm text-danger-600 dark:text-danger-400"
            data-testid="pipeline-stages-error"
          >
            {@form[:stages].errors |> Enum.map_join(" ", &elem(&1, 0))}
          </p>
        </div>

        <ol class="space-y-4">
          <.inputs_for :let={stage} field={@form[:stages]}>
            <li>
              <.card variant="outline" data-testid={"stage-card-#{stage.index}"}>
                <.card_content>
                  <.stage_header
                    stage={stage}
                    count={length(stages_list(@params))}
                    collapsed={MapSet.member?(@collapsed, stage.index)}
                  />

                  <div
                    class={["mt-5 space-y-2", MapSet.member?(@collapsed, stage.index) && "hidden"]}
                    data-testid={"stage-body-#{stage.index}"}
                  >
                    <div class="grid gap-4 sm:grid-cols-2">
                      <.icon_field
                        field={stage[:name]}
                        icon="hero-tag"
                        label="Nome"
                        data-testid={"stage-name-#{stage.index}"}
                      />
                      <.icon_field
                        field={stage[:key]}
                        icon="hero-key"
                        label="Chave"
                        help_text="Nome do artefato; em branco, vem do nome."
                        data-testid={"stage-key-#{stage.index}"}
                      />
                    </div>

                    <.markdown_editor
                      id={stage_id(stage.index)}
                      field={stage[:prompt]}
                      label="Prompt"
                      testid={"stage-prompt-#{stage.index}"}
                      variables={Prompt.variables()}
                    />

                    <div>
                      <.block_heading icon="hero-cog-6-tooth" title="Execução" />
                      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
                        <.icon_field
                          field={stage[:max_attempts]}
                          icon="hero-arrow-path"
                          type="number"
                          min="1"
                          max="5"
                          label="Tentativas"
                          data-testid={"stage-attempts-#{stage.index}"}
                        />
                        <.icon_field
                          field={stage[:model]}
                          icon="hero-sparkles"
                          type="select"
                          label="Modelo"
                          options={model_options()}
                          data-testid={"stage-model-#{stage.index}"}
                        />
                        <.icon_field
                          field={stage[:max_budget_usd]}
                          icon="hero-banknotes"
                          type="number"
                          step="0.01"
                          min="0"
                          label="Teto de custo (US$, opcional)"
                          help_text="Vazio é sem limite."
                          data-testid={"stage-budget-#{stage.index}"}
                        />
                        <.icon_field
                          field={stage[:timeout_minutes]}
                          icon="hero-clock"
                          type="number"
                          min="1"
                          max="1440"
                          label="Tempo máximo (min)"
                          data-testid={"stage-timeout-#{stage.index}"}
                        />
                      </div>
                    </div>

                    <div>
                      <.block_heading icon="hero-shield-check" title="Verificação" />
                      <div class="grid gap-4 sm:grid-cols-2">
                        <.icon_field
                          field={stage[:gates_text]}
                          icon="hero-shield-check"
                          type="textarea"
                          rows="3"
                          label="Gates (comandos depois da etapa)"
                          placeholder={gates_placeholder()}
                          help_text="Um por linha; ! na frente quando o comando deve falhar. Um gate não atendido reprova a tentativa."
                          class="font-mono text-sm"
                          data-testid={"stage-gates-#{stage.index}"}
                        />
                        <.icon_field
                          field={stage[:rules_text]}
                          icon="hero-hand-raised"
                          type="textarea"
                          rows="3"
                          label="Pedir ajuda quando"
                          placeholder="bem_definida == false"
                          help_text="Um por linha: campo == valor ou campo != valor, sobre a saída estruturada. A tarefa para e pede uma decisão."
                          class="font-mono text-sm"
                          data-testid={"stage-rules-#{stage.index}"}
                        />
                      </div>
                    </div>

                    <details class="group">
                      <summary class="flex cursor-pointer list-none items-center gap-2 text-sm font-medium text-gray-600 dark:text-gray-300">
                        <.icon
                          name="hero-chevron-right"
                          class="size-4 transition group-open:rotate-90"
                        />
                        <.icon name="hero-adjustments-horizontal" class="size-4" />
                        Avançado: agente, grupo em paralelo e saída estruturada
                      </summary>
                      <div class="mt-4 space-y-4">
                        <div class="grid gap-4 sm:grid-cols-2">
                          <.icon_field
                            field={stage[:agent]}
                            icon="hero-user-circle"
                            label="Rodar como o agente (opcional)"
                            placeholder="revisor"
                            help_text="Um agente do repositório (.claude/agents) ou do pipeline."
                            data-testid={"stage-agent-#{stage.index}"}
                          />
                          <.icon_field
                            field={stage[:group]}
                            icon="hero-squares-2x2"
                            label="Grupo em paralelo (opcional)"
                            placeholder="auditorias"
                            help_text="Etapas seguidas com o mesmo grupo rodam juntas; a seguinte espera todas."
                            data-testid={"stage-group-#{stage.index}"}
                          />
                        </div>
                        <.icon_field
                          field={stage[:output_schema_json]}
                          icon="hero-code-bracket-square"
                          type="textarea"
                          rows="5"
                          label="Campos extras da saída estruturada (JSON Schema)"
                          placeholder={
                            ~s({"type": "object", "properties": {"arquivos": {"type": "array", "items": {"type": "string"}}}})
                          }
                          class="font-mono text-sm"
                          no_margin
                          data-testid={"stage-schema-#{stage.index}"}
                        />
                      </div>
                    </details>
                  </div>
                </.card_content>
              </.card>
            </li>
          </.inputs_for>
        </ol>

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

  attr :stage, Phoenix.HTML.Form, required: true
  attr :count, :integer, required: true
  attr :collapsed, :boolean, required: true

  defp stage_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <button
        type="button"
        phx-click="toggle_stage"
        phx-value-index={@stage.index}
        aria-expanded={to_string(not @collapsed)}
        class="flex min-w-0 flex-1 items-start gap-3 text-left"
        data-testid={"stage-toggle-#{@stage.index}"}
      >
        <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary-600 text-sm font-semibold text-white dark:bg-primary-500">
          {@stage.index + 1}
        </span>
        <span class="min-w-0">
          <span class="flex items-center gap-1.5 font-semibold text-gray-900 dark:text-white">
            <span class="truncate">{(present(@stage[:name].value) && @stage[:name].value) ||
              "Nova etapa"}</span>
            <.icon
              name="hero-chevron-down"
              class={["size-4 shrink-0 text-gray-400 transition", @collapsed && "-rotate-90"]}
            />
          </span>
          <span
            class="mt-1.5 flex flex-wrap gap-1.5"
            data-testid={"stage-chips-#{@stage.index}"}
          >
            <span
              :for={{icon, text} <- stage_chips(@stage)}
              class="inline-flex items-center gap-1 rounded-md bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300"
            >
              <.icon name={icon} class="size-3.5" />
              {text}
            </span>
          </span>
        </span>
      </button>
      <div class="flex gap-1">
        <.button
          type="button"
          size="xs"
          variant="ghost"
          color="gray"
          icon="hero-arrow-up"
          title="Subir"
          disabled={@stage.index == 0}
          phx-click="move_stage"
          phx-value-index={@stage.index}
          phx-value-to={@stage.index - 1}
          data-testid={"stage-up-#{@stage.index}"}
        >
          <span class="sr-only">Subir</span>
        </.button>
        <.button
          type="button"
          size="xs"
          variant="ghost"
          color="gray"
          icon="hero-arrow-down"
          title="Descer"
          disabled={@stage.index == @count - 1}
          phx-click="move_stage"
          phx-value-index={@stage.index}
          phx-value-to={@stage.index + 1}
          data-testid={"stage-down-#{@stage.index}"}
        >
          <span class="sr-only">Descer</span>
        </.button>
        <.button
          type="button"
          size="xs"
          variant="ghost"
          color="danger"
          icon="hero-trash"
          title="Remover etapa"
          phx-click="remove_stage"
          phx-value-index={@stage.index}
          data-testid={"stage-remove-#{@stage.index}"}
        >
          <span class="sr-only">Remover</span>
        </.button>
      </div>
    </div>
    """
  end
end
