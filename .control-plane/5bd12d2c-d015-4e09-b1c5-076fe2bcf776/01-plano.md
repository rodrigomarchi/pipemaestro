# Plano — Dividir o board do workspace (`/w/:slug`) em abas

Base: `origin/main` em `509e101` (a branch já estava em dia; nenhum commit alheio).

## Entendimento

Hoje `PipeMaestroWeb.BoardLive` (`apps/pipe_maestro_web/lib/pipe_maestro_web/live/board_live.ex`)
empilha numa página só: alertas, stat cards, kanban com filtros, decisões pendentes, atividade
recente e executores. Depois desta mudança, `/w/:slug` vira uma página com abas (`?aba=`),
no mesmo padrão de `PipeMaestroWeb.RunnerLive` (`live/runner_live.ex`, `live/runner_live/*_tab.ex`):

| `aba` | Rótulo | Ícone | Conteúdo | Contador |
|---|---|---|---|---|
| `visao` (padrão) | Visão geral | `hero-home` | "Precisa de atenção" (se houver alertas), 4 stat cards, as 3 próximas decisões e as 5 últimas atividades, cada bloco com "ver tudo" | nº de alertas, só se > 0, `color="danger"` |
| `tarefas` | Tarefas | `hero-view-columns` | kanban de 4 colunas e os filtros, como hoje | — |
| `decisoes` | Decisões | `hero-hand-raised` | lista completa de decisões, vazio "Nenhuma decisão pendente", botão "Decidir" | nº aguardando decisão, só se > 0 (mesma regra do item da sidebar) |
| `atividade` | Atividade | `hero-clock` | as 20 tarefas mais recentes, com status e "há X" | — |
| `executores` | Executores | `hero-server-stack` | tabela de runners ao vivo, botão "Gerenciar" | `online/total`, sempre |

Critérios de aceite verificáveis (da tarefa):
1. `/w/:slug` abre na Visão geral com alertas e stat cards; sem kanban, tabela de runners ou lista completa de decisões.
2. Cada aba tem `data-testid="board-tab-<id>"`, navega por `live_patch` e marca a ativa; `?aba=inexistente` cai na Visão geral.
3. Filtros do kanban na URL, sobrevivendo a reload.
4. Contadores ao vivo, inclusive com outra aba aberta.
5. Testes LiveView para a aba padrão, cada aba (com e sem o conteúdo das outras), `?aba=` inválido, filtros vindos da URL e um contador mudando ao vivo.
6. E2E existentes ajustados e passando; um passo percorre as abas e tira `shot` de cada uma.
7. `make ci` e `make e2e` verdes; `make e2e.shots` conferido claro/escuro, desktop e estreito.

## Mudanças por app

### `apps/pipe_maestro` (domínio) — **não muda**

Tudo o que as abas e os contadores precisam já existe:
- `Tasks.list_tasks/2` (filtros por string; ignora vazios; id inválido vira `where false`, então
  valores arbitrários vindos da URL não quebram nada);
- `Tasks.list_awaiting/1`, `Tasks.stats/2`, `Tasks.alerts/2`, `Tasks.alerts_change_at/1`;
- `RunnerTelemetry.degraded_alerts/1`, `Runners.list_runners/1`;
- **Contador de decisões:** `Tasks.count_awaiting/1` já é mantido ao vivo em `@pending_decisions`
  por `PipeMaestroWeb.UserAuth.follow_pending_decisions/2` (hook que trata
  `{:pending_decisions, count}` e alimenta o badge da sidebar). A `BoardLive` reaproveita esse
  assign; nenhuma função nova de contagem.
- A atividade continua ordenando `Tasks.list_tasks/1` por `updated_at` na web, como hoje
  (`Enum.take(20)` / `Enum.take(5)`).

### `apps/pipe_maestro_web` — muda

**`live/board_live.ex`** fica fina:
- `@tabs [{"visao", "Visão geral", icon}, {"tarefas", …}, {"decisoes", …}, {"atividade", …}, {"executores", …}]`
  e `@tab_ids`; `@filter_keys ~w(pipeline runner_id project_id user_id)`.
- `mount/3`: assina os mesmos tópicos (`RunnerStatus`, `Tasks {:workspace, id}`, `Jobs {:workspace, id}`),
  `tab: "visao"`, `filters: %{}`, `alerts_timer: nil`. Sem carga de aba no mount.
- `handle_params/3`: `tab` válido ou `"visao"`; `filters = Map.take(params, @filter_keys)`;
  depois `load/1`.
- `handle_event("filter", %{"filters" => f})`: `push_patch` para
  `~p"/w/#{slug}?#{query}"` com `aba=tarefas` e só os filtros não vazios. Os valores seguem como
  hoje para `Tasks.list_tasks/2`.
- Carga:
  - **sempre** (contadores): `load_runners/1` (runners, `online`, `now` — barato, e dá `online/total`)
    e `load_alerts/1` (alertas + o timer `:alerts_expired`, como hoje). O contador de decisões vem de
    `@pending_decisions`.
  - **por aba** (`load_tab/2`, como `RunnerLive.load_tab/4`), delegando a `XTab.load/…`:
    - `visao`: `stats` + `Enum.take(list_awaiting, 3)` + 5 recentes;
    - `tarefas`: `tasks` filtradas, `projects`, `pipelines`, `members` (saem do mount);
    - `decisoes`: `list_awaiting`;
    - `atividade`: 20 recentes;
    - `executores`: nada além do que já é carregado sempre.
- Eventos ao vivo:
  - `presence_diff` / `:runners_changed` → `load_runners` + `load_alerts` + `load_tab` se a aba usa runners
    (`executores`; `tarefas` usa a lista de runners no filtro, já coberta por `load_runners`);
  - `{:task_updated, _}` → `load_alerts` + `load_tab` da aba ativa;
  - `{:job_updated, _}` → recarrega só se a aba ativa é `visao` (stats/custo);
  - `:alerts_expired` → `load_alerts`.
  Nenhum catch-all: todas as mensagens assinadas têm cláusula explícita.
- Render: `<.tabs variant="underline" class="overflow-x-auto" data-testid="board-tabs">` com
  `<.tab link_type="live_patch" to={tab_path(...)} is_active={@tab == id} variant="underline"
  data-testid={"board-tab-#{id}"}>`, ícone, rótulo e `<.badge size="xs" … data-testid="board-tab-count-<id>">`
  quando houver contador. `tab_path(slug, "visao")` = `/w/:slug` (sem parâmetro). `:actions` com
  "Nova tarefa" permanece.
- `@moduledoc` descreve as abas, como o de `RunnerLive`.

**Novos módulos em `live/board_live/`** (`use PipeMaestroWeb, :html`, `@moduledoc`, `@spec` em todo `def`):
- `OverviewTab` — `load/2`, componente `overview/1`; recebe o card de alertas (`alert_line/1`,
  `alert_testid/1`, `reason_label` via `RunnerComponents`) e o `stat_card/1`; resumo de decisões e
  atividade com testids próprios (para não duplicar os da aba cheia): `board-overview-decisions`,
  `board-overview-decision-<id>`, `board-overview-no-decisions`, `board-overview-decisions-all`,
  `board-overview-activity`, `board-overview-activity-all`.
- `TasksTab` — `load/2` (com filtros), `tasks/1`; recebe `@columns`, `column/1`, `column_tasks/2`,
  o form `#board-filters` e `options/2`. Testids `board-filter-*`, `board-column-*`, `board-task-*`,
  `board-card-project` mantidos.
- `DecisionsTab` — `load/1`, `decisions/1`; `board-decision-<id>`, `board-no-decisions`,
  `board-decisions-link` mantidos.
- `ActivityTab` — `load/1` (20 itens), `activity/1`; `board-activity` mantido.
- `RunnersTab` — `runners/1`; `board-runners`, `board-runner-*`, `board-runner-status-*`,
  `board-no-runners`, `board-runners-link` mantidos.
- `stage_label/1` (usado no kanban e nas decisões) vai para um lugar compartilhado: uma função
  pública em `PipeMaestroWeb.TaskComponents` (já importado) ou num pequeno módulo do board. Decido na
  implementação pelo `TaskComponents` se não houver conflito de nome.

Nada muda em Channels, rotas (`/w/:workspace_slug` continua a mesma rota) ou na sidebar
(`sidebar-board` continua levando a `/w/:slug`, que é a aba padrão).

### `apps/pipe_maestro_protocol` — **não muda**
### `apps/pipe_maestro_runner` — **não muda**

## Fronteiras

Toda a mudança fica em `pipe_maestro_web`, que já depende do domínio e do protocolo. O domínio
não ganha nada de web; o runner não é tocado. Regra de dependências preservada.

## Protocolo

Não toca `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels dos runners.
`docs/specs/protocolo-runner.md` não muda, a versão não sobe; runners antigos não são afetados.

## Telas

Muda só o Board (`/w/:slug`). Componentes Petal: `tabs`/`tab` (`variant="underline"`,
`link_type="live_patch"`, como em `RunnerLive`), `badge`, `card`, `card_header`, `card_content`,
`table`, `empty`, `button`, `icon_field` — os mesmos já usados, conferidos em `docs/guias/ui-petal.md`.

Testids novos (padrão `e2e/README.md`): `board-tabs`, `board-tab-<id>`
(`visao|tarefas|decisoes|atividade|executores`), `board-tab-count-<id>` (`visao|decisoes|executores`),
e os `board-overview-*` acima. Todos os existentes ficam, cada um na sua aba.

Largura estreita: `overflow-x-auto` na barra de abas (igual ao Runner); o kanban mantém o seu
`overflow-x-auto` com `min-w-[56rem]`.

### E2E
- `e2e/pages/AppPage.ts`: `openBoard(slug, tab?)` abre `/w/:slug[?aba=…]`; `openBoardTab(tab)` clica
  `board-tab-<tab>` e espera a aba ativa; `boardTabCount(tab)` locator.
- `e2e/tests/task-pipeline.spec.ts` (l. ~292): depois de `sidebar-board`, `board-stat-succeeded` na
  Visão geral; depois `openBoardTab("tarefas")` para `board-task-*` e `board-column-done`;
  `shot(…, "board")` tirado no kanban. **Novo passo** ali: percorre as 5 abas e tira
  `shot(…, "board-<id>")` de cada uma, inclusive em viewport estreita para a barra de abas
  (`page.setViewportSize`, como o README orienta). Esse spec é escolhido porque já tem tarefas em
  todos os estados, uma decisão e um runner online.
- `e2e/tests/user-session.spec.ts` (l. 35): `board-column-running` → ir à aba Tarefas antes (ou trocar
  por `board-tabs`/`board-stat-running` na Visão geral, mantendo o flow "vai direto ao board").
  Prefiro manter `board-column-running` via aba Tarefas, para não mudar o que o flow verifica.
- `e2e/tests/board-alerts.spec.ts` e `runner-telemetry.spec.ts`: alertas continuam na Visão geral
  (padrão) — sem mudança de navegação; acrescento a checagem do contador `board-tab-count-visao`
  no `board-alerts` (contador ao vivo no navegador).
- `e2e/director/landing.spec.ts` (l. 107): `app.openBoard(workspace.slug, "tarefas")`; o shot segue
  chamado `"board"` (ADR 0030).

## Testes (ExUnit, `apps/pipe_maestro_web/test/pipe_maestro_web/live/`)

`board_live_test.exs`:
- "groups the tasks by state…": kanban em `?aba=tarefas`; stats numa visita à Visão geral.
- testes de alertas: continuam na aba padrão; um novo afirma `board-tab-count-visao` com o número.
- "filters by…": abre `?aba=tarefas`, faz `render_change` e afirma `assert_patch` com a query; um
  novo teste abre direto `?aba=tarefas&pipeline=…&runner_id=…` e vê só as tarefas filtradas e o
  select preenchido (prova do reload/link compartilhado).
- novos: aba padrão sem `board-column-*`, sem `board-runners` e sem `board-decision-*` (só
  `board-overview-*`); cada aba mostra o seu e não o das outras; `?aba=inexistente` = Visão geral
  (`board-tab-visao` ativo); clique em `board-tab-<id>` faz `live_patch` (`assert_patch`).
- contador ao vivo: com a aba `atividade` aberta, uma tarefa vai a `awaiting_decision` →
  `board-tab-count-decisoes` aparece com 1; um runner entra na presença → `board-tab-count-executores`
  passa de `0/1` a `1/1`; o alerta de offline → `board-tab-count-visao`.
- "an empty workspace points to the first task": `board-no-decisions` em `?aba=decisoes` (ou
  `board-overview-no-decisions` na padrão).
- "shows the workspace's real runners, live": em `?aba=executores`.

`work_by_project_live_test.exs` (`describe "the board"`): `live(conn, ~p"/w/#{slug}?aba=tarefas")`;
o `render_change` do filtro passa a gerar patch — ajustar o assert para seguir o patch
(`assert_patch` e então `has_element?`).

## Documentação

- **ADR:** não. O padrão de abas por `?aba=` já foi adotado em `RunnerLive` (ADR 0039 e plano 05);
  aqui é reaplicado, sem decisão nova de arquitetura.
- `@moduledoc` da `BoardLive` e dos novos módulos.
- `docs/guias/instalacao.md:158` e `docs/plano/05-telemetria-do-runner.md` citam "alerta no Board":
  continua verdadeiro (Visão geral). Sem mudança; no máximo "na Visão geral do Board" no guia.
- `e2e/README.md`: nenhuma regra nova.

## Riscos

- **Dados/migrações:** nenhum.
- **Contadores com outra aba aberta:** alertas e runners passam a ser recomputados em todo evento,
  independentemente da aba (como hoje); o custo é o mesmo de hoje ou menor, porque a lista de tarefas
  completa (`Tasks.list_tasks/1` duas vezes por `{:task_updated, _}`) só roda nas abas que a usam.
- **Timer `:alerts_expired`:** continua único e cancelado a cada recomputação; a lógica sai como está.
- **`@pending_decisions`** depende do hook em `UserAuth`; se a `BoardLive` deixar de passar pela
  `live_session` com esse `on_mount`, o contador some — coberto pelo teste de contador ao vivo.
- **`push_patch` no `phx-change`:** cada mudança de select gera um patch; `handle_params` recarrega
  só a aba Tarefas. O form deve refletir os filtros da URL (`to_form(@filters, as: "filters")`).
- **Testids duplicados:** o resumo da Visão geral usa testids `board-overview-*` para não colidir com
  os da aba cheia em specs que somam elementos.
- **Cobertura (60%) e Dialyzer:** módulos novos com `@spec` e testados por aba; `load/…` retornam
  mapas tipados de forma simples (`map()`), como em `RunnerLive.HealthTab`.
- **Credo:** `BoardLive` encolhe; aliases dos tabs no topo (`alias PipeMaestroWeb.BoardLive.{…}`).

## Sequência de implementação (commits)

1. Extrair os componentes das abas para `live/board_live/*_tab.ex` e a navegação por `?aba=` na
   `BoardLive`, com carga por aba; ajustar os testes LiveView.
2. Contadores nas abas e filtros na URL, com os testes de contador ao vivo e de filtros pela URL.
3. E2E: `AppPage`, specs ajustados, passo que percorre as abas com `shot`, diretor da landing.
4. `make ci`, `make e2e`, `make e2e.shots` (claro/escuro, desktop/estreito) e ajustes visuais.
