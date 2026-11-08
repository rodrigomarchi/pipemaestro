# 01 — Plano: página da tarefa em fases (pipeline vertical + painel da etapa)

Base: `origin/main` em `52230b6` (fast-forward; a branch não tinha commits próprios).

## Entendimento

Hoje `PipeMaestroWeb.TaskLive.Show` (`apps/pipe_maestro_web/lib/pipe_maestro_web/live/task_live/show.ex`,
~1.800 linhas) carrega com `Tasks.get_task!/2` todos os `stage_runs` com o `Job`
completo e renderiza, na aba **Etapas**, o diagrama horizontal e, abaixo, cada
tentativa inteira (artefato em Markdown→HTML, resultado, gates, setup, arquivos,
passo a passo). Cada `{:task_updated, task}` re-renderiza tudo. O ao vivo segue só
o **primeiro** job `:running` (`follow_running_job/1`).

Depois da mudança, para quem usa:

1. **Visão geral leve:** a aba Etapas mostra o pipeline **na vertical** (entrada →
   passos → entrega quando `delivery == "pr"` → fim), cada nó só com marcador,
   nome, badge de estado, nº de tentativas (>1), "em paralelo · grupo" e, se
   terminou, duração e custo da última tentativa. Nó em execução destacado (info,
   spinner) e nó aguardando decisão em warning. Em telas largas, ao lado: alertas
   de runner, aviso de decisão, cartão de mensagem/pausa/interrupção e "Corrigir
   com um prompt". No celular, uma coluna.
2. **Painel da etapa sob demanda:** clicar num nó faz `push_patch` para
   `?etapa=<key>` (junto de `?aba=`) e abre um painel de **90% da viewport**
   (100% no celular), com fundo escurecido clicável. Fecha no X, Esc, clique no
   fundo e voltar do navegador. Link direto/reload abre na mesma etapa; `key`
   inexistente é ignorada.
3. **No painel:** cabeçalho (nome, badge, grupo, números da tentativa, link de
   auditoria, "Refazer a partir daqui"), seletor de tentativas, e conforme o estado:
   decisão pendente (razão, análise, questionário, "Decidir sem responder"),
   execução ao vivo **daquele** job (timeline em stream, `typing`, "até agora"),
   concluída (artefato primeiro, arquivos, detalhes dobráveis, passo a passo sob
   demanda com filtros), pendente (`stage_details/1` + "ainda não rodou").
4. **Aviso de decisão** acima do diagrama, com `decision_reason` e o botão
   **Decidir**, que abre o painel da etapa que espera.

Cabeçalho, ações, outras abas e o modal "Refazer a partir daqui" continuam iguais.

### Critérios de aceite verificáveis

Os 13 critérios da tarefa, cada um ligado a um teste na seção **Testes**. Resumo:
HTML da visão geral sem artefato/resultado e sem `Jobs.list_events/1` no mount (1);
`?etapa=` abre/fecha e é deep-link (2); ao vivo filtrado por job e transição para
concluída sem reload (3); paralelo (4); decisão no painel (5); ações e abas sem
regressão (6); função de domínio testada (7); `show.ex` fino, Credo/Dialyzer (8);
modos `:read/:edit/:compact/:micro` e `side_panel/1` iguais (9); `make ci` (10);
`make e2e` (11); `make e2e.shots` auditado (12); ADR nova + ADR 0040 §6 + moduledoc (13).

## Mudanças por app

### `apps/pipe_maestro` (domínio) — muda, sem migração

Em `PipeMaestro.Tasks` (`apps/pipe_maestro/lib/pipe_maestro/tasks.ex`):

- **`get_task_overview!(workspace, id) :: Task.t()`** — a tarefa com
  `:runner, :created_by_user, :decision_owner` e os `stage_runs` (ordem de
  `attempts_query/0`) numa **projeção leve**:
  - `StageRun` via `select: struct(r, [...])` sem `artifact`, `structured_output`,
    `summary`, `feedback`, `instructions`, `answers` (ficam `nil`); mantém `id`,
    `index`, `key`, `name`, `attempt`, `requeue`, `status`, `error`, `task_id`,
    timestamps;
  - `Job` via `select: struct(j, [...])` só com `id`, `status`, `cost_usd`,
    `duration_ms`, `stage_run_id`, `runner_id` e timestamps — o suficiente para
    `PipelineDiagram.task_states/1`, `waiting_for_runner?/2` (`queued_job?/1` lê
    `job.status`), duração/custo do nó e o link de auditoria.
  - Dialyzer: os campos omitidos ficam `nil`, que os tipos dos schemas já
    admitem; documentar no `@doc` que a projeção não serve para ler o conteúdo.
- **`stage_attempts(task, index) :: [StageRun.t()]`** — as tentativas de **uma**
  etapa (`where: r.task_id == ^task.id and r.index == ^index`, mesma ordem), com
  o `Job` completo. É o que o painel carrega ao abrir e ao recarregar.
- **`changed_files(task) :: [map()]`** — os arquivos alterados pela tarefa até
  agora (o `changes["task_files"]` do último job que o tem), que a aba
  **Arquivos** e a contagem da aba usam hoje via `task_files/1` sobre os jobs
  completos. Uma consulta pequena (`order_by desc`, `limit 1`, `where not is_nil`
  no JSON), para a página não precisar do `changes` em memória.
- `get_task!/2`, `notify/1` e os tópicos de PubSub **não mudam**: outros
  assinantes (Board, lista, integrações, `JobLive`) dependem do payload.
- Nenhum schema, nenhuma migração.

### `apps/pipe_maestro_web` — muda (o grosso da tarefa)

Novos módulos em `lib/pipe_maestro_web/live/task_live/`:

| Módulo | Tipo | Responsabilidade |
|---|---|---|
| `TaskLive.Show` | LiveView (fino) | `mount`, `handle_params` (`aba`, `etapa`), inscrições (`{:task, id}`, `RunnerStatus`, `{:job, id}` do job seguido), repasse ao painel por `send_update`, ações da tarefa (`cancel`, `rerun`, `instruct`, `request_pause`, `interrupt`, `retry_merge`, `remove_worktree`, `correct`, `open_redo`/`close_redo`/`redo`, `decide`, `questionnaire`, `suggest_decision`), abrir/fechar etapa (`push_patch`). |
| `TaskLive.PipelineView` | componentes de função | `vertical_pipeline/1` (o diagrama vertical a partir de `PipelineDiagram.build/2`), `stage_node/1` leve, `decision_banner/1`, `task_sidebar/1` (alertas de runner, mensagem/pausa/interrupção, "Corrigir com um prompt", `rerun_runner/1`). |
| `TaskLive.StagePanel` | LiveComponent | estado do painel: `stage`, `runs` (de `Tasks.stage_attempts/2`), tentativa selecionada, `raw_artifacts`, `timelines`, `step_filters`, stream `:timeline` + `timeline_tail`, `typing`, `spent`, `live_job_id`. Eventos próprios com `phx-target={@myself}`: `select_attempt`, `toggle_artifact`, `toggle_steps`, `filter_steps`. |
| `TaskLive.AttemptComponents` | componentes de função | `attempt/1`, `run_details/1`, `artifact/1`, `run_files/1`, `run_steps/1`, `gate_results/1`, `setup_report/1` e os auxiliares `run_ref/1`, `artifact_first?/2`, `details_open?/1`, `details_summary/1`, `plain_result?/1`, `attempts/1` — movidos de `show.ex` sem mudar regra nem test ids. |
| `TaskLive.DecisionPanel` | componente de função | razão, `analysis_state/1`, `QuestionnaireLive`, `decision-manual` com `decision-form`, opções, Refazer, Seguir, "Sugerir com IA". Os eventos (`decide`, `questionnaire`, `suggest_decision`) seguem sem `phx-target`, logo vão ao LiveView, como hoje. |
| `TaskLive.SummaryTab`, `RequestTab`, `FilesTab`, `AttachmentsTab`, `DecisionsTab` | componentes de função | as abas, no padrão de `live/board_live/*_tab.ex`, com o markup atual. |

**Visão geral — decisão de desenho:** um componente vertical próprio
(`PipelineView.vertical_pipeline/1`) que lê o **mesmo modelo**
(`PipelineDiagram.build(PipelineDiagram.for_task(task), states: PipelineDiagram.task_states(task))`:
`entry`, `steps` com `parallel?`/`group`/`nodes`, `delivery`, `waiting?`, `done?`)
e o mesmo vocabulário (`stage_state_marker/1`, `stage_state_badge/1`,
`state_label/1`). **Não** adicionar `orientation` a `pipeline_diagram/1`: as
cláusulas de `column/1`, `fork/1` e `stage_node/1` são todas pensadas em colunas
(grid horizontal, trilho "Pessoa decide"), e um modo vertical ali multiplica
ramos e põe em risco os modos `:read/:edit/:compact/:micro` (critério 9). A
coluna vertical: um trilho (linha) à esquerda, nós empilhados; um passo em
paralelo mostra as etapas lado a lado (`grid sm:grid-cols-2`) entre um
"bifurca" e um "junta" (ícones `hero-arrows-pointing-out`/`in`), e no celular
empilhadas. O trilho "Pessoa decide" não aparece na vertical; o aviso de decisão
faz esse papel. Os dados do nó (duração/custo da última tentativa, nº de
tentativas) saem de uma função pura em `PipelineView` sobre `task.stage_runs`
leves (agrupa por `index`, última por `{attempt, requeue}`).

Cada nó é um `<.link patch={...?aba=etapas&etapa=key}>` (ou `phx-click="open_stage"`
+ `push_patch`): preferir `<.link patch>`, que dá o histórico do navegador de graça.

**Painel de 90%:** estender `PipelineComponents.side_panel/1` com
`attr :size, :atom, default: :lg, values: [:lg, :wide]` e
`attr :backdrop, :boolean, default: false`. `:lg` mantém exatamente as classes de
hoje (`pc-slideover__box--lg`), então `pipeline_live/form.ex` e
`pipeline_explorer.ex` não mudam. `:wide` usa `w-full lg:w-[90vw] max-w-none`
(conferir no CSS do Petal se `pc-slideover__box` impõe `max-width`), conteúdo
com `overflow-y-auto` por dentro. `backdrop` renderiza um `div` fixo
`bg-gray-900/50` com `phx-click="close_panel"` atrás do `aside`
(`data-testid="task-stage-panel-backdrop"`). O `close_panel` da tarefa (sem
`target`) chega ao Show, que faz `push_patch` sem `etapa`. Esc continua via
`phx-window-keydown`.

**URL e ciclo de vida do painel (`handle_params`):**

- `etapa` resolvida contra `task.stages` (`Enum.find_index(&(&1.key == key))`);
  inexistente → `stage: nil` (painel fechado, nenhum erro).
- O StagePanel é renderizado só com etapa aberta (`:if`), com `id="task-stage-panel"`
  fixo e `stage_index` como assign: trocar de etapa chama `update/2`, que recarrega
  `Tasks.stage_attempts/2` e reseta o estado (tentativa selecionada = a mais
  recente, timelines, filtros, stream).
- Depois de `handle_params`, o Show calcula o **job a seguir**: o job da tentativa
  mais recente da etapa aberta se estiver `:running` (ou `:queued`/`:running`
  conforme `Job.active?/1`), senão `nil`. `follow/2`: se mudou, faz
  `Phoenix.PubSub.unsubscribe` do tópico do anterior — exposto como
  **`Jobs.unsubscribe/1`** no domínio, ao lado de `Jobs.subscribe/1` (sem mudar
  tópico nem payload) — e `Jobs.subscribe({:job, novo})`. Guarda `followed_job_id`.
- Ao abrir uma etapa em execução, o StagePanel inicia o stream com
  `Jobs.list_events(job)` → `timeline_items(events, "all")`, `stream(..., reset: true)`
  e `timeline_tail/1`; `spent` com `Insights.live(job)`. Só no painel, nunca no mount
  da visão geral.

**Roteamento de eventos de job no Show** (sem catch-all):

- `{:job_event, %{job_id: id}}` com `id == followed_job_id` →
  `send_update(StagePanel, id: "task-stage-panel", job_event: event)`; outro id → descarta
  (cláusula explícita por `job_id`, não `_`).
- `{:job_delta, id, text}` idem, `typing`.
- `{:job_telemetry, id}` com throttle `@live_every` no Show (`live_pending`) →
  `{:refresh_spent, id}` → `Jobs.get_job!` + `Insights.live/1` → `send_update(..., spent: ...)`.
- `{:job_updated, job}` (chega do tópico `{:job, id}`) → ignorado explicitamente
  como hoje (o fim vem por `{:task_updated, ...}`).
- `Broadcast "presence_diff"`, `:runners_changed` → `load_online/1`.

**`{:task_updated, task}`:** recarrega a projeção leve com
`Tasks.get_task_overview!/2` (o payload de `notify/1` às vezes vem sem
`stage_runs` carregados, e é pesado; recarregar evita guardá-lo) — depois
`load_decisions`, `load_files`, `load_rerun`, `changed_files`, e recalcula o job
seguido. **O painel só recarrega se a etapa aberta mudou:** o Show compara uma
impressão das tentativas da etapa aberta (`{id, status, updated_at, job.status}`
na projeção leve) antes/depois e só então faz `send_update(StagePanel, reload: true)`.
Ao terminar a tentativa, o reload traz o job completo, o painel deixa de estar
"ao vivo" e mostra o artefato (critério 3) — sem reload de página.

**Layout da aba Etapas:** `grid lg:grid-cols-[minmax(0,1fr)_22rem] gap-6`:
coluna 1 = `decision_banner` (acima) + `vertical_pipeline`; coluna 2 =
`task_sidebar`. No celular, uma coluna (banner, alertas, diagrama, cartões).

**Peso de render:** `Markdown.to_html/1` só roda no painel para a tentativa
selecionada (o seletor mostra uma tentativa por vez). O `@task` da página não
carrega artefato/resultado. `@files` (metadados de `Files.list_for_task/1`)
continua no Show (contagem da aba Anexos) e é passado ao painel.

**Componentes Petal** (conferir attrs em `docs/guias/ui-petal.md` e no source
antes de usar): `.card`/`.card_content`, `.badge`, `.button` (incl.
`link_type="live_patch"` no nó, se ficar melhor que `<.link patch>`), `.alert`,
`.tabs`/`.tab` do Petal ou `TabComponents` para o seletor de tentativas
(preferir um grupo de `.button` segmentado se o `.tabs` não aceitar `patch`/
`phx-click` com target), `.icon`, `.modal` (refazer, inalterado),
`.markdown_editor`, `.icon_field`, `.section_heading`.

### `apps/pipe_maestro_protocol` — **não muda**

### `apps/pipe_maestro_runner` — **não muda**

## Fronteiras

- O domínio ganha `Tasks.get_task_overview!/2`, `Tasks.stage_attempts/2`,
  `Tasks.changed_files/1` e `Jobs.unsubscribe/1`: só Ecto/PubSub, nada de web.
- A web usa o domínio e componentes próprios; nenhum código novo no runner ou no
  protocolo. A regra (runner → só `protocol`; domínio sem web) não é tocada.

## Protocolo

A mudança **não toca** `apps/pipe_maestro_protocol` nem o formato das mensagens dos
Channels dos runners. `docs/specs/protocolo-runner.md` não muda, a versão do
protocolo não sobe, runners antigos não são afetados (compatíveis por
construção). Os tópicos e payloads de PubSub internos (`Tasks.notify/1`,
broadcasts de `Jobs`) também ficam como estão; só se adiciona `Jobs.unsubscribe/1`,
o par de `subscribe/1` sobre os mesmos tópicos.

## Telas

Muda só `/w/:workspace_slug/tasks/:id` (aba Etapas; abas restantes só mudam de
módulo). `side_panel/1` ganha attrs com padrão que preserva os usos atuais.

**`data-testid` novos:**

- `task-stage-<key>` — nó vertical (link); `task-stage-state-<key>` (badge do nó);
  `task-stage-attempts-<key>`, `task-stage-group-<key>`, `task-stage-metrics-<key>`;
- `task-overview` (coluna do diagrama), `task-sidebar` (coluna lateral);
- `task-decision-banner`, `task-decision-open`;
- `task-stage-panel`, `task-stage-panel-close`, `task-stage-panel-backdrop`,
  `task-stage-panel-title`, `task-stage-panel-pending` (etapa que nunca rodou);
- `task-stage-attempt-<key>-<attempt>` (seletor; com `-r<requeue>` quando houver
  reexecução, seguindo `run_ref/1`).

**Mantidos** (o elemento continua existindo, agora no painel ou na lateral):
`stage-run-*` (status, details, details-toggle, steps, steps-toggle,
steps-filter, files, file-*, spent, tokens, audit, lost, setup, feedback,
artifact…), `task-events`, `decision-panel`, `decision-reason`, `decision-manual`,
`decision-manual-toggle`, `decision-form`, `decision-option-*`, `decision-retry`,
`decision-advance`, `decision-suggest`, `decision-instructions`, `stage-redo-<key>`
(agora no cabeçalho do painel), `stage-redo-modal/-text/-runner/-submit`,
`task-correct*`, `instruct-form`, `task-instruct*`, `task-request-pause`,
`task-pause-requested`, `task-interrupt`, `task-pending-instructions`,
`task-waiting-runner`, `task-runner-offline(-interrupt)`, abas (`task-tab-*`,
`task-panel-*`), cabeçalho. **Removidos** (o elemento deixa de existir):
`task-diagram` (o diagrama horizontal), `task-pipeline` (a lista `<ol>`),
`stage-<key>` / `stage-state-<key>` / `stage-group-<key>` / `stage-attempts-<key>`
(substituídos pelos `task-stage-*` do nó). Os specs que os usam são adaptados.

**Playwright** (`e2e/`):

- `e2e/pages/TasksPage.ts`: `openStage(key)` (clica `task-stage-<key>`, espera
  `task-stage-panel`), `closeStage()` (X / Esc / `page.goBack()`),
  `selectAttempt(key, attempt)`, `decisionBanner()`, `openDecision()`; os
  helpers `stageRun*` passam a pressupor o painel aberto (ou abrem a etapa).
- Adaptar `e2e/tests/task-pipeline.spec.ts`, `task-files.spec.ts`,
  `decision-questionnaire.spec.ts`, `runner-restart.spec.ts` (`stageRunLost`,
  reexecução `-r1`) e conferir `agent-proposals.spec.ts`, `notifications.spec.ts`,
  `job-execution.spec.ts` e `e2e/pages/JobsPage.ts`, que tocam a página da tarefa.
- Novos cenários (em `task-pipeline.spec.ts`): visão geral sem artefato no DOM;
  abrir/fechar pelo X, Esc, fundo e voltar; deep link `?etapa=`; etapa ao vivo;
  concluída com artefato; decisão pelo banner; celular (viewport estreito).
- `shot()` em: visão geral, painel ao vivo, painel concluída com artefato,
  painel com decisão pendente, celular — claro e escuro via `make e2e.shots`.
- `pipeline-diagram.spec.ts` e `pipeline-stage-context.spec.ts` rodam sem
  mudança (critério 9).

## Testes

**`apps/pipe_maestro/test/pipe_maestro/tasks_test.exs`** (critério 7):

- `get_task_overview!/2`: traz as tentativas em ordem com `job.status`,
  `cost_usd`, `duration_ms`; **não** traz `artifact`/`structured_output` do run
  nem `result`/`prompt`/`stderr`/`insights` do job; outro workspace → `Ecto.NoResultsError`.
- `stage_attempts/2`: só a etapa pedida, em ordem `attempt`/`requeue`, com jobs
  completos (artefato, resultado); índice sem tentativas → `[]`.
- `changed_files/1`: o `task_files` do último job que o tem; sem nenhum → `[]`.
- `Jobs.unsubscribe/1` em `jobs_test.exs`: depois dele, um broadcast no tópico não chega.

**`apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs`**:

- (1) tarefa com etapas concluídas: `has_element?("[data-testid=task-stage-#{key}]")`,
  ausência de `stage-run-artifact-*` e do texto do artefato e do resultado no
  HTML; `Jobs.list_events/1` não chamado no mount — provado indiretamente (a
  timeline `task-events` não existe e nenhum evento aparece) e, de forma direta,
  com um evento gravado cujo texto não aparece no HTML da visão geral.
- (2) `element("[data-testid=task-stage-#{key}]") |> render_click()` →
  `assert_patch(view, ~p".../tasks/#{id}?aba=etapas&etapa=#{key}")` e
  `task-stage-panel` com o artefato primeiro; `close_panel` → `assert_patch` sem
  `etapa`; `live(conn, "...?etapa=#{key}")` abre direto; `?etapa=nao-existe` → painel ausente.
- (3) etapa em execução aberta: `send(view.pid, {:job_event, evento_do_job})` aparece em
  `task-events`; `{:job_delta, ...}` aparece como digitação; `{:job_telemetry, id}`
  atualiza `stage-run-spent-*` (adaptar o teste atual "what it spent so far");
  um evento de outro job não aparece; concluir a etapa no domínio
  (`{:task_updated, ...}` real) troca para o artefato.
- (4) grupo em paralelo (pipeline de fixture com duas etapas no mesmo `group`,
  ambas `:running`): abrir A mostra evento de A e não de B; abrir B mostra o de B
  e deixa de receber A.
- (5) adaptar `describe "deciding"` e `describe "the decision questionnaire"`:
  `task-decision-banner` + `task-decision-open` → painel da etapa; os passos de
  hoje (opções, retry, advance, questionário, análise ao vivo, outra sessão
  responde) seguem iguais dentro do painel.
- (6) adaptar sem apagar: "talking to the task", "again", "show" (gates e feedback,
  mudanças, arquivos, anexos, worktree, setup, ao vivo até sucesso, filtros do
  passo a passo, gasto, bloqueada, diagrama ao vivo, runner offline, cancelar),
  "merging the pull request", "a stage lost by a restarted runner" — agora abrindo
  o painel quando o elemento mora nele.
- Componentes: testes de `side_panel/1` (se houver em `pipeline_components_test`)
  ganham um caso para `size: :wide` + `backdrop`, e o caso `:lg` sem backdrop
  garante o markup atual.

**Playwright:** ver **Telas**. `make e2e` e `make e2e.shots` (claro e escuro), com
as imagens lidas e copiadas para `$CP_FILES_DIR` na etapa de verificação.

**Gate:** `make ci` (compile sem warnings, format, unlock, Credo strict, testes
com cobertura ≥ 60% por app, Dialyzer sem ignores).

## Documentação

- **ADR nova** `docs/adr/0046-pagina-da-tarefa-em-fases.md`: pipeline vertical
  leve + painel por etapa; etapa na URL (`?etapa=<key>`, `push_patch`);
  projeção leve da tarefa (`get_task_overview!/2`) e carga por etapa
  (`stage_attempts/2`); streaming só do job da etapa aberta (subscribe/unsubscribe),
  inclusive em paralelo; por que um componente vertical próprio e não um modo de
  `pipeline_diagram/1`; o payload de `notify/1` intacto.
- **ADR 0040 §6** (`docs/adr/0040-diagrama-do-pipeline.md`, item "tarefa"):
  trocar "o diagrama ao vivo no topo; cada nó é um link para a sua etapa" por um
  apontamento para a ADR 0046.
- `@moduledoc` de `TaskLive.Show` reescrito; `@moduledoc` em cada módulo novo;
  o `@moduledoc` de `PipelineComponents` cita os attrs novos de `side_panel/1`.
- `docs/specs/`: conferir se algum spec descreve a página da tarefa (ex.:
  `maquina-de-estados-tarefa.md`) e ajustar só o que citar a tela; nenhum muda em
  substância. `e2e/README.md` só se ganhar um padrão novo de test id.

## Riscos

- **Sem migração**; dados existentes intactos. Tarefas antigas sem `key` em algum
  stage: o `key` vem do snapshot `task.stages`; conferir se pode ser `nil`
  (`stage_node.key :: String.t() | nil`) — nesse caso usar o índice como fallback
  na URL (`etapa=<index>`) e no test id. Verificar no implementar.
- **Concorrência / corrida no ao vivo:** inscrever no job antes de ler
  `Jobs.list_events/1` (mesmo cuidado do `mount` atual); eventos já vistos são
  descartados por `timeline_push/2` (`:seen`). Ao trocar de etapa, um evento do job
  antigo já na mailbox é descartado pelo filtro `job_id == followed_job_id`.
- **LiveComponent com stream:** suportado no LiveView 1.2.x; o reset de stream
  em `update/2` quando a etapa muda precisa de `reset: true`. Mensagens de PubSub
  chegam ao LiveView, não ao componente: daí o `send_update/3`.
- **Formulários dentro do componente:** eventos sem `phx-target` vão ao LiveView
  pai (decisão, questionário, redo), que precisa continuar tendo o estado de
  decisão (`@decision`, `@options`, `@questionnaire`) — passados ao painel como
  assigns. O `id` do `QuestionnaireLive` (`questionnaire-<task.id>`) não muda.
- **`side_panel/1`:** o atributo novo com default não pode alterar o markup atual;
  um teste de componente fixa isso, e os specs de pipeline rodam.
- **Projeção leve x funções de domínio:** quem lê a projeção (`task_states/1`,
  `waiting_for_runner?/2`, `attachment_runs`, `stage_name/2`) só usa campos
  mantidos; `Tasks.options/1`, `questionnaire/1`, `redo_from/4`, `correct/3`,
  `cancel_task/2`, `interrupt/2` relêem a tarefa no banco. Conferir cada ação que
  devolve `{:ok, task}` completo: o Show passa a recarregar a projeção leve em vez
  de guardar o retorno.
- **Cobertura:** mover código para módulos novos não muda o total; os testes
  novos de painel e paralelo cobrem `StagePanel`. Dialyzer: specs dos
  componentes de função (`@spec f(map()) :: Phoenix.LiveView.Rendered.t()`) e de
  `get_task_overview!/2`.
- **Specs e2e frágeis:** muitos helpers de `TasksPage.ts` supõem tudo visível; é
  a maior parte do trabalho de adaptação. Ordem: domínio → componentes extraídos
  (sem mudar tela, testes verdes) → visão geral + painel → testes LiveView →
  e2e → shots → docs.

## Ordem de implementação sugerida (commits)

1. `feat(tarefas): projeção leve da tarefa e tentativas por etapa` (domínio + testes + `Jobs.unsubscribe/1`).
2. `refactor(tarefa): componentes de tentativa e abas em módulos próprios` (sem mudança visual).
3. `feat(tarefa): pipeline vertical e painel da etapa sob demanda` (PipelineView, StagePanel, DecisionPanel, `side_panel` largo, Show fino, testes LiveView).
4. `test(e2e): fluxo de abrir a etapa no painel` (page object, specs, shots).
5. `docs(tarefa): ADR 0046 e a ADR 0040 apontando para ela`.
