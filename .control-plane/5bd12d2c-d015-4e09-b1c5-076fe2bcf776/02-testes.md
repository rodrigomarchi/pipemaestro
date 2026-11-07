# Testes que falham — board do workspace em abas

Testes escritos antes da implementação. Nenhum código de produção mudou.

## ExUnit (`apps/pipe_maestro_web`)

### `test/pipe_maestro_web/live/board_live_test.exs`

| Teste | O que afirma |
|---|---|
| `the tasks tab groups the tasks by state, live` | kanban em `?aba=tarefas`, ao vivo; sem stats, runners, decisões ou atividade |
| `the overview shows the numbers, the next decisions and the latest activity` | Visão geral: 4 stat cards, `board-overview-decision-<id>`, `board-overview-activity`, links "ver tudo"; sem `board-column-*`, `#board-filters`, `board-runners`, `board-decision-*`, `board-activity` |
| `the overview shows only the next three decisions` | 4 decisões aguardando → 3 no resumo |
| `the decisions tab lists every decision waiting` | `?aba=decisoes` lista as 4, com `board-decisions-link`; sem o resto |
| `the activity tab lists the twenty latest tasks` | `?aba=atividade` com 20 `li` em `board-activity` (21 tarefas criadas) |
| `the runners tab shows the runners and nothing else` | `?aba=executores` com `board-runner-mac` e "Offline" |
| `the counters on the tabs follow the workspace live, whatever tab is open` | aba Atividade aberta: `board-tab-count-executores` `0/1` → `1/1` → `0/1` (presença), `board-tab-count-decisoes` aparece com `1`, `board-tab-count-visao` aparece com `1` (alerta de offline) |
| `alerts on a task whose runner is offline` (ajustado) | + `board-tab-count-visao` = `1` |
| `the overview keeps its alerts to itself` | em `?aba=decisoes` o alerta não aparece, mas o contador da Visão geral sim |
| `filters by pipeline, runner, project and person, in the URL` (ajustado) | cada `render_change` em `#board-filters` faz `assert_patch` para `/w/:slug?aba=tarefas&<filtros não vazios>` (chaves em ordem alfabética, como sai de `URI.encode_query/1` de um mapa) |
| `the filters come from the URL, so a reload or a shared link keeps them` | abrir direto `?aba=tarefas&pipeline=Outro&project_id=…` filtra e deixa as `option` selecionadas |
| `a filter that matches nothing in the URL leaves the columns empty` | `project_id=nao-e-um-id` não quebra: colunas vazias |
| `the tabs › the overview is the default, and an unknown tab falls back to it` | `/w/:slug` e `?aba=inexistente`: `board-tabs`, `board-tab-visao[aria-selected=true]` |
| `the tabs › every tab is a live patch that marks itself active` | clique em `board-tab-<id>` → `assert_patch` para `?aba=<id>`, a aba fica `aria-selected=true`; `board-tab-visao` volta para `/w/:slug` |
| `an empty workspace points to the first task` (ajustado) | `board-overview-no-decisions` na Visão geral |
| `shows the workspace's real runners, live` (ajustado) | em `?aba=executores`; + contador `0/1` |

A aba ativa é verificada por `aria-selected="true"`, que o `<.tab>` do Petal emite
(`deps/petal_components/lib/petal_components/tabs.ex`).

### `test/pipe_maestro_web/live/work_by_project_live_test.exs`

`the board › filters by project…`: abre `?aba=tarefas` e afirma o `assert_patch` com `project_id`.

### Execução

`mix test apps/pipe_maestro_web/test/pipe_maestro_web/live/board_live_test.exs apps/pipe_maestro_web/test/pipe_maestro_web/live/work_by_project_live_test.exs` → 17 falhas.
Suíte inteira do app web (`cd apps/pipe_maestro_web && mix test`): **353/370 passam; as 17 falhas são exatamente esses testes**.

Trechos das falhas e por que são as esperadas:

```
the tabs every tab is a live patch that marks itself active
** (ArgumentError) expected selector "[data-testid=board-tab-tarefas]" to return a single element, but got none
```
A barra de abas ainda não existe.

```
the tabs the overview is the default, and an unknown tab falls back to it
code: assert has_element?(view, "[data-testid=board-tabs]")   Expected truthy, got false
```
Idem.

```
an empty workspace points to the first task
code: assert has_element?(view, "[data-testid=board-overview-no-decisions]")
```
O resumo de decisões da Visão geral não existe.

```
the runners tab shows the runners and nothing else
code: refute has_element?(view, "[data-testid=board-stat-running]")   Expected false or nil, got true
the decisions tab lists every decision waiting
code: refute has_element?(view, "[data-testid=board-stat-awaiting]")
the tasks tab groups the tasks by state, live
code: refute has_element?(view, "[data-testid=board-stat-running]")
```
Hoje tudo está na mesma página: `?aba=` é ignorado e os stats aparecem em qualquer "aba".

```
the overview keeps its alerts to itself
code: refute has_element?(view, "[data-testid=board-alert-offline-#{task.id}]")   Expected false or nil, got true
```
Os alertas aparecem em qualquer URL; devem ficar só na Visão geral.

```
the overview shows only the next three decisions
code:  assert shown == 3   left: 0
the overview shows the numbers, the next decisions and the latest activity
code: assert has_element?(view, "[data-testid=board-overview-decision-#{blocked.id}]", ...)
```
Os testids `board-overview-*` não existem.

```
the activity tab lists the twenty latest tasks
code:  assert Enum.count(items) == 20   left: 8
```
Hoje a atividade mostra 8 itens; a aba deve mostrar 20.

```
shows the workspace's real runners, live
alerts on a task whose runner is offline
the counters on the tabs follow the workspace live, whatever tab is open
code: assert has_element?(view, "[data-testid=board-tab-count-executores]", "0/1")
code: assert has_element?(view, "[data-testid=board-tab-count-visao]", "1")
```
Os contadores nas abas não existem.

```
the filters come from the URL, so a reload or a shared link keeps them
code: refute has_element?(view, "[data-testid=board-task-#{a.id}]")   Expected false or nil, got true
a filter that matches nothing in the URL leaves the columns empty
code: assert has_element?(view, "[data-testid=board-column-running]", "Nenhuma tarefa")
```
Os filtros da URL são ignorados hoje.

```
filters by pipeline, runner, project and person, in the URL
** (ArgumentError) expected PipeMaestroWeb.BoardLive to patch to "/w/empresa-7939?aba=tarefas&pipeline=Outro", but got none
the board filters by project and shows each card's project (WorkByProjectLiveTest)
** (ArgumentError) expected PipeMaestroWeb.BoardLive to patch to "/w/…?aba=tarefas&project_id=…", but got none
```
O filtro ainda só muda o assign, sem `push_patch`.

Nenhuma falha por sintaxe, compilação ou setup.

## E2E (Playwright)

- `e2e/pages/AppPage.ts`: `boardTabs`/`BoardTab`; `openBoard(slug, tab?)` (abre `?aba=` e espera a aba
  ativa), `boardTab(tab)`, `boardTabCount(tab)`, `openBoardTab(tab)` (clique + `aria-selected`),
  `expectBoardTab(tab)`.
- `e2e/tests/task-pipeline.spec.ts`: depois de `sidebar-board`, a Visão geral (`board-stat-succeeded` = 4,
  sem kanban), depois `openBoardTab("tarefas")` para o kanban e o `shot "board"`. Novo **flow N** (`[todo]`):
  contador `executores` com `/1`, percorre as 5 abas com `shot "board-<id>"`, recarrega e continua em
  Executores, e tira `board-tabs-narrow` a 390px.
- `e2e/tests/user-session.spec.ts`: vai à aba Tarefas antes de `board-column-running`.
- `e2e/tests/board-alerts.spec.ts`: `board-tab-count-visao` = `1` com o alerta de limite, ao vivo.
- `e2e/director/landing.spec.ts`: `openBoard(slug, "tarefas")` antes do `capture "board"`.

`make e2e.typecheck` → **passa** (exit 0). Os specs falham em execução pelo motivo certo: `openBoard`,
`openBoardTab` e `expectBoardTab` esperam `board-tab-<id>` com `aria-selected="true"`, que ainda não
existe. A suíte e2e não foi rodada nesta etapa.

## Para a implementação

- Ordem da query no `push_patch`: `aba` e os filtros não vazios, em ordem alfabética
  (`aba, pipeline, project_id, runner_id, user_id`) — o que `URI.encode_query/1` dá para um mapa.
- O `@flow N` do `task-pipeline.spec.ts` passa a `[done]` quando o spec passar.
