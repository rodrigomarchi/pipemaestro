# 02 — Testes que falham

Base: a branch estava em dia com `origin/main` e com o próprio origin (`9a4fe49`).
Nenhum código de produção mudou: só testes e o Page Object do e2e.

## O que foi escrito

| Arquivo | O que descreve | Critério |
|---|---|---|
| `apps/pipe_maestro/test/pipe_maestro/tasks/task_page_test.exs` (novo) | `Tasks.get_task_overview!/2` (projeção leve: tentativas em ordem, `job.status/cost_usd/duration_ms`, **sem** `artifact`, `structured_output`, `summary` do run nem `result`, `prompt`, `stderr`, `structured_output`, `artifact`, `insights` do job; mesmos estados da tarefa completa; só do workspace), `Tasks.stage_attempts/2` (tentativas de **uma** etapa com jobs completos; etapa sem tentativas → `[]`) e `Tasks.changed_files/1` (o `task_files` do último relatório que o tem) | 1, 7 |
| `apps/pipe_maestro/test/pipe_maestro/jobs_test.exs` (+ `describe "unsubscribe/1"`) | `Jobs.unsubscribe/1`: depois dele, o que o job retransmite não chega | 3 |
| `apps/pipe_maestro_web/test/pipe_maestro_web/components/pipeline_components_test.exs` (+2 testes em `side_panel/1`) | por padrão continua `pc-slideover__box--lg`, `data-size=lg`, sem fundo; com `size: :wide` e `backdrop: true`, `data-size=wide`, sem `--lg`, fundo `<testid>-backdrop` com `phx-click=close_panel` | 9, UI |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_stage_panel_test.exs` (novo) | a página em fases, abaixo | 1–6 |
| `e2e/tests/task-stage-panel.spec.ts` (novo) + `e2e/pages/TasksPage.ts` (métodos novos) | o fluxo no navegador, com `shot()` das telas pedidas | 11, 12 |

### LiveView (`task_live_stage_panel_test.exs`)

- **the overview**
  - *the pipeline, vertical, with each stage's state and nothing of what it produced*:
    `task-overview` › `task-stage-<key>`, `task-stage-state-<key>`, `data-state`,
    `task-stage-metrics-a` ("1 min 01 s", "US$ 0.5000"); o HTML **não** contém o
    artefato, o resultado nem o evento já gravado da etapa em execução (prova de que
    `Jobs.list_events/1` não roda no mount); nenhum `stage-run-*`, `task-events` nem
    painel; `instruct-form` e `task-interrupt` em `task-sidebar`.
  - *a stage with more than one attempt says how many* (`task-stage-attempts-a`).
  - *follows the task, live* (os estados mudam com `{:task_updated, …}`, sem artefato).
- **a stage's panel**
  - *opens from its node, in the URL, artifact first; closes by X, Escape, backdrop and back*:
    `assert_patch` com `etapa=a`; `task-stage-panel-title`, `stage-run-artifact-a-1`,
    detalhes fechados, link de auditoria, alternar texto/renderizado; fechar por
    `task-stage-panel-close`, `render_keydown` Escape, `task-stage-panel-backdrop` e
    `render_patch` sem `etapa`.
  - *a link to the stage opens it; an unknown stage is ignored*.
  - *a stage that never ran says what it will do* (`task-stage-panel-pending`, o prompt da etapa).
  - *with several attempts, the latest shows and a selector picks another* (`task-stage-attempt-a-<n>`).
  - *redoes from the stage, by its panel* (`stage-redo-a` dentro do painel → modal → refaz).
- **a running stage's panel**
  - *streams that job live…*: timeline começa de `list_events`, evento novo, `job-typing`,
    "até agora" com `{:refresh_spent, id}`; evento e delta **de outro job** descartados;
    ao terminar, o artefato aparece sem reload e o ao vivo some.
  - *closing the panel stops following the job*.
- **stages in parallel** — *the group's nodes say so, and each running stage opens its own live*:
  `task-stage-group-<key>`, duas etapas `running`; o painel de `seg` só mostra `seg`; trocar
  para `perf` reinicia a timeline com o que `perf` disse e passa a seguir só `perf`.
- **a pending decision** — *a banner over the pipeline opens the waiting stage…*:
  `task-decision-banner` com a razão, `task-decision-open` → `?etapa=a`; `decision-panel`,
  `decision-reason`, `decision-option-1`, `decision-suggest` dentro do painel; o
  `decision-form` refaz com a escolha, o aviso some e o painel fica na tentativa 2.

### Playwright (`task-stage-panel.spec.ts`)

Cabeçalho `@section`/`@flow` (A–E), nomes com `uniqueSuffix()`, só `getByTestId`.
Usa o fake agent: `[lento]` (30 s, para ver a etapa rodando) e `[bloqueio]`/`[desbloqueio]`.

1. *the pipeline is light; a stage opens in a wide panel, live and then finished*: visão geral
   sem painel nem `task-events`; abrir o nó → painel ≥ 85% da largura, `task-events` e
   "até agora"; termina → artefato sem reload; fechar por Escape, X e `goBack()`; link com
   `?etapa=` abre; `expectFitsPhone` com painel e sem. Shots: `task-overview`,
   `task-stage-panel-live`, `task-stage-panel-finished`, `task-stage-panel-phone`,
   `task-overview-phone`.
2. *a pending decision is taken from the waiting stage's panel*: banner, `openDecision()`,
   `retryWith(...)`, tarefa concluída, seletor de tentativas. Shots:
   `task-decision-banner`, `task-stage-panel-decision`.

`TasksPage.ts` ganhou: `overview`, `sidebar`, `stageNode`, `stageNodeState`, `stagePanel`,
`openStage`, `closeStage`, `closeStageWithEscape`, `expectStageClosed`, `selectAttempt`,
`liveEvents`, `stageRunArtifact`, `decisionBanner`, `openDecision`. Os métodos existentes
não mudaram; os specs antigos (`task-pipeline`, `task-files`, `decision-questionnaire`,
`runner-restart`) serão adaptados na implementação, junto com `task_live_test.exs`.

## Execução: falham pelo motivo certo

### Domínio — `mix test apps/pipe_maestro/test/pipe_maestro/tasks/task_page_test.exs apps/pipe_maestro/test/pipe_maestro/jobs_test.exs`

`Result: 23/30 passed — Failed: 7 tests`. As 7 são as novas, todas por função inexistente:

```
** (UndefinedFunctionError) function PipeMaestro.Tasks.get_task_overview!/2 is undefined or private. Did you mean:
    * get_task!/2
** (UndefinedFunctionError) function PipeMaestro.Tasks.stage_attempts/2 is undefined or private
Expected exception Ecto.NoResultsError but got UndefinedFunctionError (function PipeMaestro.Tasks.get_task_overview!/2 is undefined or private)
** (UndefinedFunctionError) function PipeMaestro.Tasks.changed_files/1 is undefined or private. Did you mean:
    * change_task/0
** (UndefinedFunctionError) function PipeMaestro.Jobs.unsubscribe/1 is undefined or private. Did you mean:
    * subscribe/1
```

Esperado: as funções do plano ainda não existem. O setup (tarefa, runner, `finish_job`
com `cost_usd`, `duration_ms`, `changes`) roda sem erro. Os 23 testes antigos de `jobs_test.exs` passam.

### Web — `mix test .../live/task_live_stage_panel_test.exs .../components/pipeline_components_test.exs`

`Result: 25/39 passed — Failed: 14 tests`: os 12 da página nova e os 2 novos de `side_panel/1`.
Os testes antigos de `pipeline_components_test.exs` passam.

```
side_panel/1 wide…            code: assert count(html, "#p[data-size=wide]") == 1      left: 0
side_panel/1 … by default     code: assert count(html, "#p[data-size=lg]") == 1         left: 0
the overview … vertical …     code: assert has_element?(view, "[data-testid=task-overview] [data-testid=task-stage-a]")   Expected truthy, got false
the overview … attempts       code: assert has_element?(view, "[data-testid=task-stage-attempts-a]", "2 tentativas")
the overview follows …        code: assert has_element?(view, "[data-testid=task-stage-state-a]", "Executando")
opens from its node …         ** (ArgumentError) expected selector "[data-testid=task-stage-a]" to return a single element, but got none
a link to the stage …         code: assert has_element?(view, "[data-testid=task-stage-panel] [data-testid=stage-run-a-1]")
never ran …                   code: assert has_element?(view, "#{panel} [data-testid=task-stage-panel-pending]")
several attempts …            code: assert has_element?(view, "[data-testid=task-stage-attempt-a-1]")
redoes … by its panel         ** (ArgumentError) expected selector "[data-testid=task-stage-panel] [data-testid=stage-redo-a]" … got none
streams that job live …       code: refute has_element?(view, "[data-testid=task-events]")   Expected false or nil, got true
closing the panel …           ** (ArgumentError) expected selector "[data-testid=task-stage-panel-close]" … got none
stages in parallel …          code: assert has_element?(view, "[data-testid=task-stage-group-seg]", "em paralelo · auditorias")
a pending decision …          code: assert has_element?(view, "[data-testid=task-decision-banner]", "Onde corrigir?")
```

Esperado: os elementos da página nova (`task-overview`, `task-stage-*`, painel, banner,
seletor) e os attrs novos de `side_panel/1` não existem. O caso
*streams that job live* falha justamente porque a página atual **mostra a timeline no mount**,
que é o comportamento que muda. Nenhuma falha é de setup, sintaxe ou compilação.

### Testes existentes

`mix test apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs apps/pipe_maestro/test/pipe_maestro/tasks_test.exs apps/pipe_maestro_web/test/pipe_maestro_web/live/pipeline_live_test.exs`
→ `Result: 94 passed` e `Result: 66 passed`. Eles descrevem a página atual e serão
adaptados, não apagados, na implementação (critério 6).

### Playwright

- `make e2e.typecheck` → exit 0.
- `E2E_FORGEJO_PORT=4813 E2E_GITHUB_PORT=4814 make e2e FILE=tests/task-stage-panel.spec.ts`:
  outra sessão ocupava a porta 4013 do Forgejo falso, e as variáveis do helper levaram os
  dois servidores falsos a outras portas. Resultado: **2 failed**. As duas passam pelo setup
  inteiro (workspace, runner real, projeto, pipelines, tarefa criada; no segundo, a tarefa
  chega a "Aguardando decisão") e param no primeiro elemento novo:

```
1) … the pipeline is light; a stage opens in a wide panel, live and then finished
   Error: expect(locator).toBeVisible() failed
   Locator: getByTestId('task-overview')    Error: element(s) not found      (task-stage-panel.spec.ts:88)
2) … a pending decision is taken from the waiting stage's panel
   Error: expect(locator).toContainText(expected) failed
   Locator: getByTestId('task-decision-banner')    Expected substring: "navegador"    Error: element(s) not found   (task-stage-panel.spec.ts:145)
```

## Notas para a implementação

- Nomes fixados pelos testes: `Tasks.get_task_overview!/2`, `Tasks.stage_attempts/2`,
  `Tasks.changed_files/1`, `Jobs.unsubscribe/1`; `side_panel/1` com `size` (`:lg` | `:wide`,
  exposto em `data-size`) e `backdrop` (`<testid>-backdrop`, `phx-click="close_panel"`).
- Nó do diagrama: `task-stage-<key>` com `data-state`, clicável (patch para `?etapa=`);
  `task-stage-state-<key>`, `task-stage-metrics-<key>` (só com a etapa terminada),
  `task-stage-attempts-<key>` (só com mais de uma), `task-stage-group-<key>`.
- O fechar pelo X usa o `<testid>-close` que `side_panel/1` já gera (`task-stage-panel-close`).
- O Escape é testado com `render_keydown` no `aside` (o `phx-window-keydown` de `side_panel/1`).
- Na visão geral, não pode haver nenhum `[data-testid^=stage-run-]`.
