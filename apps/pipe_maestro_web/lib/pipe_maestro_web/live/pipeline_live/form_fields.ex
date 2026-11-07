defmodule PipeMaestroWeb.PipelineLive.FormFields do
  @moduledoc """
  The fields of `PipeMaestroWeb.PipelineLive.Form`: the pipeline's
  identification, execution and context, and a stage's header and body. Each
  is rendered once in the form; the form only decides the frame around it (a
  card in the Formulário tab, a side panel in the Diagrama tab).
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.PipelineComponents, only: [stage_chips: 1]

  alias PipeMaestro.Pipelines.{Prompt, Stage}
  alias PipeMaestro.Tasks.Contract
  alias PipeMaestroWeb.PipelineDiagram

  @deliveries [
    {"none", "Nenhuma: os prompts decidem", "hero-no-symbol",
     "A plataforma não confere nem entrega nada; o que acontece com o código fica a cargo dos prompts."},
    {"commit", "Commits conferidos, sem push", "hero-check-badge",
     "O agente faz os commits na branch da tarefa; a plataforma confere cada etapa (abaixo) e não faz push."},
    {"pr", "Commits conferidos, push e PR", "hero-rocket-launch",
     "O agente faz os commits; a plataforma confere cada etapa (abaixo), faz o push e mantém o seu bloco no PR, que abre em rascunho e fica pronto na última etapa."}
  ]

  @doc "The name a stage's form shows: its name, or that it is new."
  @spec stage_title(Phoenix.HTML.Form.t()) :: String.t()
  def stage_title(stage) do
    name = stage[:name].value
    if is_binary(name) and String.trim(name) != "", do: name, else: "Nova etapa"
  end

  attr :form, Phoenix.HTML.Form, required: true

  @doc "The pipeline's name and description."
  def identity_fields(assigns) do
    ~H"""
    <.section_heading
      icon="hero-identification"
      title="Identificação"
      description="Como o pipeline aparece na lista e ao criar uma tarefa."
    />
    <.icon_field field={@form[:name]} icon="hero-tag" label="Nome" data-testid="pipeline-name" />
    <.icon_field
      field={@form[:description]}
      icon="hero-bars-3-bottom-left"
      type="textarea"
      rows="2"
      label="Descrição"
      no_margin
      data-testid="pipeline-description"
    />
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  @doc "The pipeline's cost cap and delivery, with the platform's checks."
  def execution_fields(assigns) do
    assigns = assign(assigns, delivery: delivery(assigns.form[:delivery].value))

    ~H"""
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
      <.icon name={elem(@delivery, 2)} class="mt-0.5 size-4 shrink-0 text-primary-500" />
      {elem(@delivery, 3)}
    </p>
    <div
      :if={Contract.labels(@form[:delivery].value) != []}
      class="mt-3 rounded-lg bg-gray-50 px-3 py-2 text-sm dark:bg-gray-950"
      data-testid="pipeline-platform-checks"
    >
      <p class="mb-1 font-medium text-gray-700 dark:text-gray-200">
        Verificações da plataforma, em toda etapa que entrega
      </p>
      <ul class="list-inside list-disc space-y-0.5 text-gray-600 dark:text-gray-300">
        <li :for={label <- Contract.labels(@form[:delivery].value)}>{label}</li>
      </ul>
      <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
        Fixas, como gates que vêm antes dos seus: uma que falha volta ao agente com o motivo.
        Etapas em grupo (paralelas) ficam de fora.
      </p>
    </div>
    """
  end

  defp delivery_options, do: Enum.map(@deliveries, fn {value, label, _, _} -> {label, value} end)

  defp delivery(value),
    do: Enum.find(@deliveries, hd(@deliveries), fn {key, _, _, _} -> key == value end)

  attr :form, Phoenix.HTML.Form, required: true

  @doc "What every stage runs with: system instructions, MCP servers and agents."
  def context_fields(assigns) do
    ~H"""
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
          placeholder={~s({"revisor": {"description": "Revisa o diff", "prompt": "Revise..."}})}
          class="font-mono text-sm"
          data-testid="pipeline-agents"
        />
      </div>
    </details>
    """
  end

  attr :stage, Phoenix.HTML.Form, required: true
  attr :hidden, :boolean, default: false

  @doc "A stage's fields: name, key, prompt, execution, verification and the advanced ones."
  def stage_fields(assigns) do
    ~H"""
    <div class={["space-y-2", @hidden && "hidden"]} data-testid={"stage-body-#{@stage.index}"}>
      <div class="grid gap-4 sm:grid-cols-2">
        <.icon_field
          field={@stage[:name]}
          icon="hero-tag"
          label="Nome"
          data-testid={"stage-name-#{@stage.index}"}
        />
        <.icon_field
          field={@stage[:key]}
          icon="hero-key"
          label="Chave"
          help_text="Nome do artefato; em branco, vem do nome."
          data-testid={"stage-key-#{@stage.index}"}
        />
      </div>

      <.markdown_editor
        id={"stage-#{@stage.index}-prompt"}
        field={@stage[:prompt]}
        label="Prompt"
        testid={"stage-prompt-#{@stage.index}"}
        variables={Prompt.variables()}
      />

      <div>
        <.block_heading icon="hero-cog-6-tooth" title="Execução" />
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.icon_field
            field={@stage[:max_attempts]}
            icon="hero-arrow-path"
            type="number"
            min="1"
            max="5"
            label="Tentativas"
            data-testid={"stage-attempts-#{@stage.index}"}
          />
          <.icon_field
            field={@stage[:model]}
            icon="hero-sparkles"
            type="select"
            label="Modelo"
            options={[{"Padrão do CLI", ""} | Enum.map(Stage.models(), &{&1, &1})]}
            data-testid={"stage-model-#{@stage.index}"}
          />
          <.icon_field
            field={@stage[:max_budget_usd]}
            icon="hero-banknotes"
            type="number"
            step="0.01"
            min="0"
            label="Teto de custo (US$, opcional)"
            help_text="Vazio é sem limite."
            data-testid={"stage-budget-#{@stage.index}"}
          />
          <.icon_field
            field={@stage[:timeout_minutes]}
            icon="hero-clock"
            type="number"
            min="1"
            max="1440"
            label="Tempo máximo (min)"
            data-testid={"stage-timeout-#{@stage.index}"}
          />
        </div>
      </div>

      <div>
        <.block_heading icon="hero-shield-check" title="Verificação" />
        <div class="grid gap-4 sm:grid-cols-2">
          <.icon_field
            field={@stage[:gates_text]}
            icon="hero-shield-check"
            type="textarea"
            rows="3"
            label="Gates (comandos depois da etapa)"
            placeholder={gates_placeholder()}
            help_text="Um por linha; ! na frente quando o comando deve falhar. Um gate não atendido reprova a tentativa."
            class="font-mono text-sm"
            data-testid={"stage-gates-#{@stage.index}"}
          />
          <.icon_field
            field={@stage[:rules_text]}
            icon="hero-hand-raised"
            type="textarea"
            rows="3"
            label="Pedir ajuda quando"
            placeholder="bem_definida == false"
            help_text="Um por linha: campo == valor ou campo != valor, sobre a saída estruturada. A tarefa para e pede uma decisão."
            class="font-mono text-sm"
            data-testid={"stage-rules-#{@stage.index}"}
          />
        </div>
      </div>

      <details class="group">
        <summary class="flex cursor-pointer list-none items-center gap-2 text-sm font-medium text-gray-600 dark:text-gray-300">
          <.icon name="hero-chevron-right" class="size-4 transition group-open:rotate-90" />
          <.icon name="hero-adjustments-horizontal" class="size-4" />
          Avançado: agente, grupo em paralelo e saída estruturada
        </summary>
        <div class="mt-4 space-y-4">
          <div class="grid gap-4 sm:grid-cols-2">
            <.icon_field
              field={@stage[:agent]}
              icon="hero-user-circle"
              label="Rodar como o agente (opcional)"
              placeholder="revisor"
              help_text="Um agente do repositório (.claude/agents) ou do pipeline."
              data-testid={"stage-agent-#{@stage.index}"}
            />
            <.icon_field
              field={@stage[:group]}
              icon="hero-squares-2x2"
              label="Grupo em paralelo (opcional)"
              placeholder="auditorias"
              help_text="Etapas seguidas com o mesmo grupo rodam juntas; a seguinte espera todas."
              data-testid={"stage-group-#{@stage.index}"}
            />
          </div>
          <.icon_field
            field={@stage[:output_schema_json]}
            icon="hero-code-bracket-square"
            type="textarea"
            rows="5"
            label="Campos extras da saída estruturada (JSON Schema)"
            placeholder={
              ~s({"type": "object", "properties": {"arquivos": {"type": "array", "items": {"type": "string"}}}})
            }
            class="font-mono text-sm"
            no_margin
            data-testid={"stage-schema-#{@stage.index}"}
          />
        </div>
      </details>
    </div>
    """
  end

  # A multi-line placeholder: in the template, the formatter would make it literal.
  defp gates_placeholder, do: "{{projeto.teste}}\n! mix test test/repro_test.exs"

  attr :stage, Phoenix.HTML.Form, required: true
  attr :count, :integer, required: true
  attr :collapsed, :boolean, required: true

  @doc "A stage's card header: number, name and chips (it collapses the card), and its moves."
  def stage_header(assigns) do
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
            <span class="truncate">{stage_title(@stage)}</span>
            <.icon
              name="hero-chevron-down"
              class={["size-4 shrink-0 text-gray-400 transition", @collapsed && "-rotate-90"]}
            />
          </span>
          <.stage_chips
            chips={PipelineDiagram.chips(Ecto.Changeset.apply_changes(@stage.source))}
            class="mt-1.5"
            testid={"stage-chips-#{@stage.index}"}
          />
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
