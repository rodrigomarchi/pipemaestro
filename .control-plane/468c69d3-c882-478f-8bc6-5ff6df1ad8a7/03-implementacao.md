# 03 — Implementação

A branch estava em dia com `origin/main` e com o próprio origin. Commits desta etapa:

1. `feat(tarefas): projeção leve da tarefa, tentativas por etapa e Jobs.unsubscribe/1`
2. `feat(tarefa): pipeline vertical e painel da etapa sob demanda`
3. `test(tarefa): sugerir decisão e commit da etapa pelo painel`
4. `test(e2e): fluxo de abrir a etapa no painel nos specs da tarefa`

## O que mudou por app

### `apps/pipe_maestro` (domínio): sem migração

- `PipeMaestro.Tasks.get_task_overview!/2`: a tarefa numa carga leve, com
  `:runner`, `:created_by_user`, `:decision_owner` e os `stage_runs` em ordem.
  - O `StageRun` e o `Job` vêm por `select: struct(...)`.
  - Do run vêm id, índice, key, nome, tentativa, requeue, status, erro e timestamps.
  - Do job vêm id, status, custo, duração, início e fim, chaves e timestamps.
  - Ficam `nil` o artefato, o resumo e o `structured_output` do run, e o prompt,
    o resultado, o stderr e os insights do job.
- `PipeMaestro.Tasks.stage_attempts/2`: as tentativas de uma etapa, com os jobs completos.
- `PipeMaestro.Tasks.changed_files/1`: o `changes["task_files"]` do último relatório
  que o tem. Alimenta a aba Arquivos sem carregar os jobs.
- `PipeMaestro.Jobs.unsubscribe/1`: o par de `subscribe/1`, sobre os mesmos tópicos.
- `get_task!/2`, `notify/1` e os payloads e tópicos de PubSub **não mudaram**.

### `apps/pipe_maestro_web`

| Módulo | O que é |
|---|---|
| `TaskLive.Show` (reescrito, fino) | `mount` com `get_task_overview!/2`, `handle_params` (`aba`, `etapa`; key desconhecida → painel fechado), as inscrições, o repasse ao painel por `send_update/3`, as ações e decisões da tarefa. `follow_job/1` segue o job da tentativa em execução **da etapa aberta** e faz `unsubscribe` do anterior. Cada handler de `job_*` tem uma cláusula para o job seguido e outra explícita que descarta os demais; não há catch-all. O throttle `@live_every` foi mantido. Depois de `{:task_updated, _}` e de cada ação, a tarefa é relida na carga leve (`refresh/1`). |
| `TaskLive.PipelineView` | `overview/1` é o pipeline vertical sobre `PipelineDiagram.build/2` com `task_states/1`. O caminho é entrada → passos → entrega quando `:pr` → fim, e um grupo em paralelo fica em grade. O nó é `<.link patch>` para `?aba=etapas&etapa=<key>`, com `data-state`, e mostra badge, tentativas, grupo e, quando terminou, duração e custo. O módulo também traz `decision_banner/1`, `task_sidebar/1` (alertas de runner, mensagem, pausa e interrupção, "Corrigir com um prompt"), `rerun_runner/1`, `stage_path/3`, `awaiting_key/1` e `no_pr?/1`. |
| `TaskLive.StagePanel` (LiveComponent) | Guarda as tentativas da etapa (carregadas ao abrir e quando a `fingerprint` muda), a tentativa escolhida, os artefatos em texto, os passos abertos e os filtros. Guarda também o stream `:timeline` ao vivo (resetado com `Jobs.list_events/1` quando o job seguido muda), `typing` e `spent`. Recebe `job_event`, `job_delta` e `spent` por `send_update`. O seletor mostra uma tentativa por vez, a mais recente por padrão; uma reexecução por runner perdido aparece junto da tentativa a que pertence. |
| `TaskLive.AttemptComponents` | `attempt`, `run_details`, `artifact`, `run_files`, `run_steps`, `gate_results`, `setup_report`, `run_ref` e `attempts`, saídos de `show.ex` com as mesmas regras (`artifact_first?`, `details_open?`, `details_summary`, `plain_result?`) e os mesmos test ids. Os eventos de tentativa ganharam `phx-target`. |
| `TaskLive.DecisionPanel` | Razão, análise, `QuestionnaireLive` e o formulário `decision-form`. Os eventos continuam indo ao LiveView. |
| `TaskLive.SummaryTab`, `RequestTab`, `FilesTab`, `AttachmentsTab`, `DecisionsTab` | As abas, com o markup de antes. |
| `PipelineComponents.side_panel/1` | Ganhou `size` (`:lg` por padrão, com as classes de antes, ou `:wide`: `w-full lg:w-[90vw]`, conteúdo que rola por dentro), `backdrop` (fundo `<testid>-backdrop` que fecha com `close_panel`), `data-size` e `<testid>-title`. Os usos em `pipeline_live/form.ex` e `pipeline_explorer.ex` não mudaram. |

`fingerprint/2` em `Show` reúne, para cada tentativa da etapa aberta,
`{id, status, updated_at, {job.status, job.updated_at}}`. O painel só relê do
banco quando ela muda, quando a etapa muda ou quando muda o job seguido.

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`: não mudam

O protocolo não foi tocado; os runners antigos não são afetados.

## Testes ajustados (sem enfraquecer)

- **Spec `e2e/tests/task-stage-panel.spec.ts`:** o spec da etapa 2 procurava
  `getByTestId("instruct-form")`, mas esse formulário tem só `id` (o test id dele
  sempre foi dos campos e botões). A verificação da coluna lateral passou a usar
  `task-interrupt`, que tem testid e só aparece com a tarefa rodando.
- **`task_live_test.exs`** foi adaptado, e nenhum teste foi apagado. Onde o elemento
  mudou para o painel, o teste abre a etapa (`?etapa=a`, ou o clique no nó ou no
  "Decidir"):
  - `stage-state-*` passou a `task-stage-state-*`, e `stage-correcao-1` a `task-stage-correcao-1`;
  - o teste do diagrama horizontal virou "the pipeline follows the task, live, and
    each node leads to its stage" (nós `task-stage-*`, `data-state`, `href` com
    `etapa=`, banner);
  - no teste de gates, o painel abre na tentativa 2 (com o feedback) e o seletor
    leva à 1, onde estão os gates.
- **`proposal_live_test.exs`** e **`pull_requests_live_test.exs`** abrem a etapa
  (banner ou nó) antes de `decision-suggest` e de `stage-run-commit-a-1`.
- **e2e:**
  - Em `TasksPage.ts`:
    - `decisionReason` passou a ser o banner (`task-decision-banner`);
    - `openManualDecision` abre o painel da decisão quando ele não está visível;
    - `correct`, `interrupt`, `removeWorktree`, `backToList` e `openTab` fecham o
      painel aberto antes de clicar, porque o fundo cobre a página;
    - entrou `closeStageIfOpen`.
  - `task-pipeline`, `task-files`, `decision-questionnaire` e `runner-restart`
    abrem a etapa (`openStage` ou `openDecision`) onde leem `stage-run-*`.
  - As verificações do diagrama horizontal da tarefa viraram verificações dos nós verticais.

## Como verificar

| Verificação | Resultado |
|---|---|
| `mix test apps/pipe_maestro/test/pipe_maestro/tasks/task_page_test.exs apps/pipe_maestro/test/pipe_maestro/jobs_test.exs` | 30 passed |
| `mix test apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_stage_panel_test.exs` | 12 passed |
| `mix test apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs` | 34 passed |
| `mix test …/components/pipeline_components_test.exs` | 27 passed |
| `make ci.quick > /tmp/ciq.log 2>&1; echo $?` | **0**: Credo sem issues; protocol 113, domínio 592, web 521, runner 273 testes; cobertura acima de 60% |
| `mix dialyzer` | 0 erros |
| `make e2e.typecheck` | 0 |
| `make e2e FILE=tests/task-stage-panel.spec.ts` | 2 passed |
| `make e2e` dos specs afetados (task-pipeline, task-files, decision-questionnaire, runner-restart, agent-proposals, notifications, job-execution, pipeline-diagram, pipeline-stage-context) | 11 passed |
| `make e2e.shots FILE=tests/task-stage-panel.spec.ts` | 18 imagens, claro e escuro, copiadas para `$CP_FILES_DIR/implementacao/task-stage-panel/` |

Os e2e rodaram com `E2E_FORGEJO_PORT=4813 E2E_GITHUB_PORT=4814` porque outra
sessão ocupava a porta 4013 do Forgejo falso.

Auditoria rápida das imagens:
- visão geral com o pipeline vertical e a coluna lateral;
- painel ao vivo (timeline e "até agora") cobrindo ~90% da largura, com o fundo escurecido;
- painel concluído com o artefato primeiro e os detalhes dobrados;
- decisão (razão, diagnóstico, questionário, "Decidir sem responder") no topo do painel;
- celular numa coluna, sem rolagem lateral.

A auditoria completa dos shots dos outros fluxos fica para a etapa de verificação.

## Pendências para as próximas etapas

- A documentação (ADR nova, apontamento na ADR 0040 §6) fica para a etapa de
  documentação. O `@moduledoc` de `TaskLive.Show` já foi reescrito.
- `make ci` completo: nesta etapa, rodei `make ci.quick` e `mix dialyzer` separados, ambos verdes.
