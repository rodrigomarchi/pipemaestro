defmodule PipeMaestroWeb.PipelineLive.FormFields do
  @moduledoc """
  The fields of `PipeMaestroWeb.PipelineLive.Form`: the pipeline's and a
  stage's, each rendered once in the form, in the drawer the diagram's node
  opens. A drawer splits its fields in tabs
  (`PipeMaestroWeb.PipelineComponents.drawer_tabs/1`), the first one
  what matters most (a stage's prompt and model); a tab not chosen stays in the
  page, hidden, so its inputs still post.
  """
  use PipeMaestroWeb, :html

  import PipeMaestroWeb.PipelineComponents, only: [drawer_tabs: 1]
  import PipeMaestroWeb.TabComponents, only: [tab_panel: 1]

  alias PipeMaestro.Pipelines.{Prompt, Stage}
  alias PipeMaestro.Tasks.Contract

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

  @typedoc """
  A tab of a drawer: its id, label and icon, and the fields in it, whose
  errors mark it.
  """
  @type tab :: {String.t(), String.t(), String.t(), [atom()]}

  @entry_tabs [
    {"geral", "Geral", "hero-identification", [:name, :description, :system_prompt]},
    {"entrega", "Entrega", "hero-rocket-launch",
     [
       :max_task_cost_usd,
       :auto_analysis,
       :delivery,
       :auto_merge,
       :merge_method,
       :max_merge_fixes
     ]},
    {"avancado", "Avançado", "hero-puzzle-piece", [:mcp_config_json, :agents_json]}
  ]

  @stage_tabs [
    {"prompt", "Prompt", "hero-pencil-square", [:name, :model, :prompt]},
    {"execucao", "Execução", "hero-cog-6-tooth",
     [:max_attempts, :max_budget_usd, :timeout_minutes]},
    {"verificacao", "Verificação", "hero-shield-check", [:gates_text, :rules_text]},
    {"avancado", "Avançado", "hero-adjustments-horizontal",
     [:key, :context, :agent, :group, :output_schema_json]}
  ]

  @doc "The tabs of the entry's drawer, the first one what it opens on."
  @spec entry_tabs() :: [tab()]
  def entry_tabs, do: @entry_tabs

  @doc "The tabs of a stage's drawer, the first one what it opens on."
  @spec stage_tabs() :: [tab()]
  def stage_tabs, do: @stage_tabs

  @doc "The first of `tabs` holding one of `fields`, else the first tab."
  @spec tab_of([tab()], [atom()]) :: String.t()
  def tab_of([{first, _, _, _} | _] = tabs, fields) do
    Enum.find_value(tabs, first, fn {id, _, _, tab_fields} ->
      if Enum.any?(fields, &(&1 in tab_fields)), do: id
    end)
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :tabs, :list, required: true, doc: "a list of `t:tab/0`"
  attr :active, :string, required: true
  attr :testid, :string, required: true

  # The drawer's tabs, a tab marked when one of its fields has an error.
  defp form_tabs(assigns) do
    assigns =
      assign(assigns,
        errors:
          for(
            {id, _, _, fields} <- assigns.tabs,
            Enum.any?(fields, &(assigns.form[&1].errors != [])),
            do: id
          ),
        tabs: Enum.map(assigns.tabs, fn {id, label, icon, _fields} -> {id, label, icon} end)
      )

    ~H"""
    <.drawer_tabs tabs={@tabs} active={@active} errors={@errors} testid={@testid} />
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :tab, :string, required: true

  @doc """
  The pipeline's fields, one tab at a time: its name, description and system
  instructions; its cost cap and delivery; its MCP servers and agents.
  """
  def entry_fields(assigns) do
    ~H"""
    <.form_tabs form={@form} tabs={entry_tabs()} active={@tab} testid="pipeline-panel" />
    <.tab_panel id="geral" active={@tab} testid="pipeline-panel" class="max-w-3xl">
      <.icon_field field={@form[:name]} icon="hero-tag" label="Nome" data-testid="pipeline-name" />
      <.icon_field
        field={@form[:description]}
        icon="hero-bars-3-bottom-left"
        type="textarea"
        rows="2"
        label="Descrição"
        data-testid="pipeline-description"
      />
      <.markdown_editor
        id="pipeline-system-prompt"
        field={@form[:system_prompt]}
        label="Instruções de sistema"
        icon="hero-command-line"
        testid="pipeline-system-prompt"
        rows={6}
        help_text="Somadas às do agente em todas as etapas. Cada etapa roda com contexto novo e lê os artefatos das anteriores."
      />
    </.tab_panel>
    <.tab_panel id="entrega" active={@tab} testid="pipeline-panel" class="max-w-3xl">
      <.execution_fields form={@form} />
    </.tab_panel>
    <.tab_panel id="avancado" active={@tab} testid="pipeline-panel" class="max-w-3xl">
      <.icon_field
        field={@form[:mcp_config_json]}
        icon="hero-server-stack"
        type="textarea"
        rows="6"
        label="Servidores MCP (JSON com mcpServers)"
        placeholder={~s({"mcpServers": {"grafana": {"command": "mcp-grafana"}}})}
        help_text="Valem para todas as etapas. Não guarde segredos aqui: use variáveis de ambiente do runner."
        class="font-mono text-sm"
        data-testid="pipeline-mcp-config"
      />
      <.icon_field
        field={@form[:agents_json]}
        icon="hero-user-group"
        type="textarea"
        rows="6"
        label="Agentes (JSON por nome)"
        placeholder={~s({"revisor": {"description": "Revisa o diff", "prompt": "Revise..."}})}
        help_text="Uma etapa roda como um deles pelo nome (Avançado, na etapa)."
        class="font-mono text-sm"
        no_margin
        data-testid="pipeline-agents"
      />
    </.tab_panel>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  # The pipeline's cost cap, whether failures are analysed by the agent, and
  # the delivery, with the platform's checks and, for a delivery in PR,
  # whether the platform merges it.
  defp execution_fields(assigns) do
    assigns = assign(assigns, delivery: delivery(assigns.form[:delivery].value))

    ~H"""
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
    <.field
      field={@form[:auto_analysis]}
      type="switch"
      label="Analisar falhas com IA"
      help_text="Cada pausa por falha pede ao agente um diagnóstico e perguntas (até US$ 1). Desligado, a tarefa pausa só com o erro."
      data-testid="pipeline-auto-analysis"
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
    <div
      :if={@form[:delivery].value == "pr"}
      class="mt-4 space-y-3 rounded-lg border border-gray-200 p-3 dark:border-gray-700"
      data-testid="pipeline-auto-merge-section"
    >
      <.field
        field={@form[:auto_merge]}
        type="switch"
        label="Fazer o merge do PR sozinha"
        no_margin
        data-testid="pipeline-auto-merge"
      />
      <p class="text-sm text-gray-500 dark:text-gray-400" data-testid="pipeline-auto-merge-help">
        Ao fim do pipeline, a plataforma espera os checks do repositório e faz o merge quando todos
        passam e não há conflito. Um check que falha ou um conflito volta ao agente numa etapa de
        correção. Precisa de um repositório vinculado por uma integração.
      </p>
      <div
        :if={checked?(@form[:auto_merge].value)}
        class="grid gap-3 sm:grid-cols-2"
        data-testid="pipeline-auto-merge-settings"
      >
        <.icon_field
          field={@form[:merge_method]}
          icon="hero-arrows-pointing-in"
          type="select"
          label="Como fazer o merge"
          options={[{"Squash", "squash"}, {"Merge commit", "merge"}, {"Rebase", "rebase"}]}
          no_margin
          data-testid="pipeline-merge-method"
        />
        <.icon_field
          field={@form[:max_merge_fixes]}
          icon="hero-wrench-screwdriver"
          type="number"
          min="0"
          max="10"
          label="Correções antes de desistir"
          no_margin
          data-testid="pipeline-max-merge-fixes"
        />
      </div>
    </div>
    """
  end

  defp checked?(value), do: value in [true, "true"]

  defp delivery_options, do: Enum.map(@deliveries, fn {value, label, _, _} -> {label, value} end)

  defp delivery(value),
    do: Enum.find(@deliveries, hd(@deliveries), fn {key, _, _, _} -> key == value end)

  attr :stage, Phoenix.HTML.Form, required: true
  attr :tab, :string, required: true

  @doc """
  A stage's fields, one tab at a time: its name, model and prompt; how it runs;
  how it is checked; and the advanced ones (key, context, agent, group and
  structured output).
  """
  def stage_fields(assigns) do
    assigns = assign(assigns, testid: "stage-panel-#{assigns.stage.index}")

    ~H"""
    <.form_tabs form={@stage} tabs={stage_tabs()} active={@tab} testid={@testid} />
    <div data-testid={"stage-body-#{@stage.index}"}>
      <.tab_panel id="prompt" active={@tab} testid={@testid}>
        <div class="grid gap-4 sm:grid-cols-2">
          <.icon_field
            field={@stage[:name]}
            icon="hero-tag"
            label="Nome"
            data-testid={"stage-name-#{@stage.index}"}
          />
          <.icon_field
            field={@stage[:model]}
            icon="hero-sparkles"
            type="select"
            label="Modelo"
            options={[{"Padrão do CLI", ""} | Enum.map(Stage.models(), &{&1, &1})]}
            data-testid={"stage-model-#{@stage.index}"}
          />
        </div>
        <.markdown_editor
          id={"stage-#{@stage.index}-prompt"}
          field={@stage[:prompt]}
          label="Prompt"
          testid={"stage-prompt-#{@stage.index}"}
          variables={Prompt.variables()}
          rows={14}
        />
      </.tab_panel>

      <.tab_panel id="execucao" active={@tab} testid={@testid} class="max-w-3xl">
        <.icon_field
          field={@stage[:max_attempts]}
          icon="hero-arrow-path"
          type="number"
          min="1"
          max="5"
          label="Tentativas"
          help_text="Quantas vezes a etapa roda antes de pedir ajuda, quando um gate reprova."
          data-testid={"stage-attempts-#{@stage.index}"}
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
          no_margin
          data-testid={"stage-timeout-#{@stage.index}"}
        />
      </.tab_panel>

      <.tab_panel id="verificacao" active={@tab} testid={@testid} class="max-w-3xl">
        <.icon_field
          field={@stage[:gates_text]}
          icon="hero-shield-check"
          type="textarea"
          rows="4"
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
          rows="4"
          label="Pedir ajuda quando"
          placeholder="bem_definida == false"
          help_text="Um por linha: campo == valor ou campo != valor, sobre a saída estruturada. A tarefa para e pede uma decisão."
          class="font-mono text-sm"
          no_margin
          data-testid={"stage-rules-#{@stage.index}"}
        />
      </.tab_panel>

      <.tab_panel id="avancado" active={@tab} testid={@testid} class="max-w-3xl">
        <.icon_field
          field={@stage[:key]}
          icon="hero-key"
          label="Chave"
          help_text="Nome do artefato; em branco, vem do nome."
          data-testid={"stage-key-#{@stage.index}"}
        />
        <.icon_field
          field={@stage[:context]}
          icon="hero-arrow-uturn-right"
          type="select"
          label="Contexto"
          options={[
            {"Começar do zero", "fresh"},
            {"Continuar a etapa anterior", "continue"}
          ]}
          help_text="Continuar retoma a conversa do agente da etapa anterior, que não pode estar num grupo em paralelo. Do zero, o agente só recebe os artefatos."
          data-testid={"stage-context-#{@stage.index}"}
        />
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
      </.tab_panel>
    </div>
    """
  end

  # A multi-line placeholder: in the template, the formatter would make it literal.
  defp gates_placeholder, do: "{{projeto.teste}}\n! mix test test/repro_test.exs"
end
