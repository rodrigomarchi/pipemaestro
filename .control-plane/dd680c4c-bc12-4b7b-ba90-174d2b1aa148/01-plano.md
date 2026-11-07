# Etapa 1 — Entendimento e plano: central de notificações no top bar

Base: `origin/main` em `da4d4a0` (fast-forward, sem commits alheios na branch).

## Entendimento

Hoje, em `PipeMaestroWeb.UserAuth.on_mount(:require_workspace, …)`, o hook
`follow_pending_decisions/2` assina `tasks:decisions:<ws>` e `tasks:events:<ws>`,
mantém `@pending_decisions` (badge "Decisões" na sidebar) e transforma cada
`{:task_event, …}` em toast e `push_event("notify")` (notificação do navegador em
`assets/js/app.js`). Tudo é efêmero: quem não estava numa tela do workspace perde o
aviso, e não há um lugar que mostre "o que está rodando agora" fora do board.

Depois da mudança, quem usa o workspace passa a ter, em **qualquer tela** (todo
`Layouts.app`), um **sino** no top bar, antes do `color_scheme_switch`:

- badge com as não lidas ("9+" acima de 9) e um ponto pulsante enquanto há execuções
  ativas no workspace;
- clicar abre um **painel lateral** (slide-over do Petal, direita, largura total no
  mobile) com duas abas:
  - **Em andamento**: tarefas `:running`, `:awaiting_decision`, `:queued` e propostas em
    andamento, agrupadas (*Rodando*, *Aguardando decisão*, *Na fila*), com título,
    status, "etapa N de M", runner, tempo decorrido vivo, criador e link; toggle
    "Minhas / Todas"; estado vazio "Nada rodando agora" com link para criar tarefa;
  - **Notificações**: caixa persistente (pausou, concluiu, falhou, cancelada, proposta
    pronta), com ícone/cor por tipo, corpo em Markdown resumido, tempo relativo,
    marcador de não lida, clique = abre o assunto e marca lida, "Marcar todas como
    lidas", filtro "Não lidas / Todas", "Carregar mais", estado vazio, "Ver todas";
- uma página `/w/:workspace_slug/notifications` com a lista completa e os mesmos
  filtros.

O toast e a notificação do navegador continuam, disparados pelo mesmo evento.

### Critérios de aceite verificáveis (da tarefa)

| # | Critério | Prova |
|---|---|---|
| 1 | Sino em toda tela; tarefa rodando → indicador + item em "Em andamento" com status/etapa; atualiza sem reload ao mudar de etapa/terminar | LiveView test do hook/painel + Playwright |
| 2 | Pausa/fim → notificação persistida ao criador; badge sobe ao vivo em qualquer tela; sobrevive a reload/login; toast + navegador seguem | testes de domínio (criação em `Tasks`), LiveView do hook, Playwright |
| 3 | Clicar navega e marca lida; "Marcar todas" zera o badge | LiveView + Playwright |
| 4 | Tarefa sem criador notifica admins; membro não recebe tarefa alheia; ninguém lê/marca de outro usuário/workspace | testes de domínio |
| 5 | `Maintenance` remove lidas com mais de 30 dias | teste de domínio |
| 6 | Testes de domínio, LiveView (hook, painel, página) e `e2e/tests/notifications.spec.ts` | — |
| 7 | `make e2e.shots` claro/escuro, desktop/mobile, painel nas duas abas e vazios | auditoria |
| 8 | `make ci` e `make e2e` verdes | gate |

## Decisões de desenho (tomadas aqui, com o porquê; vão para a ADR 0041)

1. **Tópico próprio para a central, não `tasks:workspace`/`jobs:workspace` no hook.**
   As LiveViews do workspace não têm `handle_info` catch-all (ex.: `RunnersLive`,
   `RunnerLive`, `UsageLive`). Se o hook assinasse `tasks:workspace:<ws>` e devolvesse
   `{:cont, socket}` para `{:task_updated, _}`, toda tela que não trata essa mensagem
   quebraria com `FunctionClauseError`; e as que já assinam (`BoardLive`, `JobsLive`…)
   receberiam cada mensagem **em dobro** (o `Phoenix.PubSub` entrega uma vez por
   assinatura). Por isso o domínio publica, nos mesmos pontos de `Tasks.notify/1` e do
   `notify/1` privado de `Jobs` (só para jobs de proposta), uma mensagem própria
   `{:executions_changed, workspace_id}` em `notifications:activity:<ws>`; o hook a
   consome e a **interrompe** (`{:halt, …}`). Mensagens que não são da central seguem
   com `{:cont, socket}`. É o que a tarefa pede ("pelo PubSub dos eventos de tarefas e
   jobs"), sem o efeito colateral.
2. **Recarga das execuções ativas com debounce.** Ao receber `{:executions_changed, _}`
   o hook agenda (uma vez) `Process.send_after(self(), :refresh_active_executions, 300)`
   e então chama `Notifications.active_executions/2`. Reconsultar é mais simples e
   correto que aplicar deltas (o struct de `notify/1` nem sempre vem com o mesmo
   preload); o debounce evita uma consulta por evento em workspace movimentado.
3. **Estado do painel num LiveComponent**, estado global no hook. O hook mantém
   `@notification_center` (um mapa: `unread`, `active` — a lista derivada —, `latest`
   — a última notificação recebida). `Layouts.app` ganha o attr
   `notification_center` e cada LiveView do workspace o repassa, igual a
   `pending_decisions` (mesmo mecanismo já usado; uma única chave para não espalhar
   vários attrs). O layout renderiza o sino e
   `<.live_component module={PipeMaestroWeb.NotificationCenter} id="notification-center" …>`,
   que guarda **aberto/fechado, aba, "Minhas/Todas", filtro e paginação** e trata os
   seus eventos com `phx-target={@myself}` — nenhum nome de evento global colide com os
   das páginas, abrir/fechar não toca no estado da página. Quando chega
   `{:notification, n}`, o hook atualiza o contador e faz
   `send_update(NotificationCenter, id: "notification-center", prepend: n)` (só tem
   efeito se o painel estiver aberto na aba de notificações).
4. **Slide-over do Petal** (`PetalComponents.SlideOver.slide_over/1`, 4.17.1, conferido
   no pacote): `origin="right"`, `max_width` (largura total no mobile via `class`),
   `close_on_click_away`, `close_on_escape`, `close_slide_over_target="#notification-center"`
   (o fechar faz `JS.push("close_slide_over", target: …)` no componente). Ele só abre
   quando montado, então é renderizado com `:if={@open}` dentro do componente. Foco: o
   sino faz `JS.push_focus()` antes de abrir e `on_close={JS.pop_focus()}` devolve o
   foco ao sino. `aria-modal`/foco inicial já vêm do componente.
5. **Abas do painel com `<.tabs>`/`<.tab>` do Petal e `phx-click`**, sem `?aba=`: um
   overlay não deve mudar a URL da página de baixo. Os ids seguem o pedido da tarefa
   (`notifications-tab-active`, `notifications-tab-inbox`). A página
   `NotificationLive` **não usa abas** (só lista + filtros na barra `:actions`), então
   a regra de `?aba=` não se aplica; o filtro "Não lidas/Todas" vai em `?filtro=` para
   sobreviver ao reload.
6. **Tempo decorrido e relativo no cliente.** Um hook JS `Elapsed`
   (`assets/js/elapsed.js`, registrado em `app.js`) lê `data-since` (ISO 8601) e
   reescreve o texto a cada segundo ("3 min 12 s") ou minuto ("há 5 min"). O servidor
   renderiza o valor inicial (sem flicker, e testes LiveView o enxergam). Nenhum timer
   no processo da LiveView.
7. **Destinatários** (`Notifications.recipients_for_task/1`): `created_by_user_id` e
   `decision_owner_id`, sem duplicar, **filtrados aos que ainda são membros** do
   workspace; se nenhum sobrar (tarefa de issue, sem criador), todos os admins do
   workspace (`Workspaces.list_memberships/1`, papel `:admin`). Quem cancelou a própria
   tarefa também recebe `:task_canceled` (o histórico fica completo, como o toast que
   já aparece para todos).
8. **`:proposal_ready`**: vai para o `created_by_user` do job quando o job de proposta
   termina `:succeeded`, para os tipos que uma pessoa revisa (`project`, `pipeline`,
   `task`, `decision`, `improve`). Ficam de fora: `analysis` (pedida pela própria
   plataforma; vira o questionário da tarefa já notificada como pausada) e a proposta
   de tarefa **auto-aprovada que virou tarefa** (não há o que revisar; a tarefa
   notificará por conta própria).
9. **Execuções ativas de proposta**: jobs com `context["proposal"]`, status `:queued |
   :running`, excluindo `analysis` (aparece como a tarefa em "Aguardando decisão").
   Propostas não têm etapas: o item mostra "proposta · <tipo>" no lugar de
   "etapa N de M".

## Mudanças por app

### `apps/pipe_maestro` (domínio)

- **Migração** `priv/repo/migrations/2026111…_create_notifications.exs`:
  - `notifications`: `id` (uuid, como `PipeMaestro.Schema`), `workspace_id`
    (`references :workspaces, on_delete: :delete_all`), `user_id`
    (`references :users, on_delete: :delete_all`), `kind` (string), `title` (string,
    not null), `body` (text), `task_id` (`references :tasks, on_delete: :delete_all` —
    sem a tarefa a notificação perde o destino), `job_id`
    (`references :jobs, on_delete: :delete_all`, idem para propostas), `read_at`
    (`utc_datetime`), timestamps (`utc_datetime`).
  - índices: `(user_id, workspace_id, read_at)`, `(user_id, workspace_id, inserted_at)`
    para a listagem paginada, e `inserted_at` (retenção); índices em `task_id` e
    `job_id` para o `on_delete`.
- **Schema** `lib/pipe_maestro/notifications/notification.ex`: `kind` como
  `Ecto.Enum` (`:task_awaiting_decision, :task_succeeded, :task_failed,
  :task_canceled, :proposal_ready`), `belongs_to` workspace/user/task/job, `@type t`.
- **Contexto** `lib/pipe_maestro/notifications.ex` (`@moduledoc`, `@doc`/`@spec` em
  tudo):
  - `list_for(scope, opts)` — `limit` (padrão 20), `before` (cursor
    `{inserted_at, id}`), `unread: true`; mais recentes primeiro; sempre
    `where user_id == scope.user.id and workspace_id == scope.workspace.id`;
    preload mínimo para o link (task/job ids já bastam);
  - `count_unread(scope)`;
  - `get_for(scope, id)` (privado ou público para a página), `mark_read(scope, id)` →
    `{:ok, n} | {:error, :not_found}` (escopo no `where`, não no Elixir),
    `mark_all_read(scope)` → `{count, nil}`; ambos publicam `{:unread_count, n}`;
  - `subscribe(scope)` — assina `notifications:user:<ws>:<user>` e
    `notifications:activity:<ws>`;
  - `notify_task(task, event_kind)` — cria em lote (`Repo.insert_all` com
    `returning: true`) para os destinatários, publica `{:notification, n}` e
    `{:unread_count, c}` no tópico de cada um; título/corpo em pt-BR
    ("<título> aguarda decisão", corpo = `decision_reason`);
  - `notify_proposal(job)` — `:proposal_ready`;
  - `executions_changed(workspace_id)` — broadcast em `notifications:activity:<ws>`;
  - `active_executions(workspace, opts)` — consulta derivada: tarefas nos três status
    com `runner`, `created_by_user`, `started_at` (a `inserted_at` da tarefa ou do
    `StageRun` corrente) e `stages` para "N de M"; propostas (`Job` com
    `context->'proposal'`, exceto `analysis`) em `:queued | :running`. Devolve uma lista
    de mapas/structs `%Notifications.Execution{}` (`id`, `type: :task | :proposal`,
    `title`, `status`, `stage`, `stage_count`, `runner_name`, `started_at`,
    `creator_id`, `creator_name`) já ordenada; `mine: user` filtra pelo criador.
    `group/1` separa em rodando/aguardando/fila (regra no domínio, não na view);
  - `delete_read_before(datetime)` para a retenção.
- **`PipeMaestro.Tasks`** (`lib/pipe_maestro/tasks.ex`): `announce/2` (único ponto de
  `await/3` e `finish/2`, que cobre também `cancel_task/2`) passa a chamar
  `Notifications.notify_task(task, kind)` logo após o `Repo.update!`; `notify/1` passa
  a chamar `Notifications.executions_changed(task.workspace_id)`. O payload de
  `{:task_event, …}` em `tasks:events` não muda (toast e navegador seguem iguais).
- **`PipeMaestro.Jobs`** (`lib/pipe_maestro/jobs.ex`): o `notify/1` privado chama
  `executions_changed/1` quando o job é proposta; `finished/1` passa a enviar **toda**
  proposta não-`analysis` para `Proposals.job_finished/1`.
- **`PipeMaestro.Proposals`** (`lib/pipe_maestro/proposals.ex`): `job_finished/1`
  mantém o comportamento atual do tipo `task` e, ao fim, chama
  `Notifications.notify_proposal/1` quando cabe (decisão 8).
- **`PipeMaestro.Maintenance`**: nova parte `notifications` em `run/2`
  (`:notifications_days`, padrão 30) apagando lidas com `read_at` anterior ao corte;
  o mapa de retorno ganha a chave.
- **`PipeMaestro.Workspaces`**: se não houver, `list_admin_ids(workspace)` (ids dos
  membros admin) e `member_ids(workspace, ids)`; senão reaproveitar
  `list_memberships/1`.

### `apps/pipe_maestro_web`

- **`PipeMaestroWeb.UserAuth`**: `on_mount(:require_workspace, …)` encadeia um hook
  irmão `follow_notifications/2` (mesmo arquivo, mesmo padrão de
  `follow_pending_decisions/2`, extraído para `PipeMaestroWeb.NotificationHooks` se o
  arquivo crescer demais). Ele:
  - assina `Notifications.subscribe(scope)` quando conectado;
  - atribui `@notification_center` (`unread`, `active`);
  - `attach_hook(:notifications, :handle_info, …)`: `{:notification, n}`,
    `{:unread_count, c}`, `{:executions_changed, _}`, `:refresh_active_executions` →
    `{:halt, …}`; o resto → `{:cont, socket}`.
  - O hook existente de `{:task_event, …}` segue igual (toast + `notify`).
- **`Layouts.app/1`** (`components/layouts.ex`): attr `notification_center`
  (map, default vazio — o backoffice não usa), sino antes de `color_scheme_switch`:
  `<.button>`/ícone `hero-bell` do Petal com `aria-label` ("Notificações, N não
  lidas"), `aria-haspopup="dialog"`, badge (`<.badge>`), ponto pulsante
  (`animate-ping` com `motion-reduce:hidden`), e o live component.
- **`PipeMaestroWeb.NotificationCenter`** (LiveComponent novo,
  `components/notification_center.ex`): slide-over, abas, lista "Em andamento"
  (agrupada por `Notifications.group/1`), lista de notificações (stream com
  `reset` no filtro), "Carregar mais" (cursor), "Marcar todas", toggle
  "Minhas/Todas", estados vazio e de carregamento (lista carregada no `open`, com
  esqueleto/spinner do Petal enquanto `@inbox == :loading` via `assign_async`).
  Clicar num item: `mark_read` + `push_navigate` para a tarefa
  (`/w/:slug/tasks/:id`) ou proposta (`/w/:slug/proposals/:id`).
- **`PipeMaestroWeb.NotificationComponents`** (`components/notification_components.ex`):
  `notification_item/1`, `execution_item/1`, `kind_icon/1` (ícone e cor por `kind`,
  com fallback genérico para um `kind` novo), usados no painel e na página.
  Corpo resumido com `PipeMaestroWeb.Markdown.to_html/1` + `line-clamp`.
- **`PipeMaestroWeb.NotificationLive`** (`live/notification_live.ex`) + rota
  `live "/w/:workspace_slug/notifications", NotificationLive` no `live_session
  :workspace`: lista completa, filtro `?filtro=`, "Carregar mais", "Marcar todas"
  em `:actions`, mesmos itens. `active` da sidebar: nenhum item novo na sidebar
  (a página é alcançada pelo sino → "Ver todas"); `Layouts.app` recebe
  `active={:notifications}`.
- **Todas as LiveViews do workspace** (as que já passam `pending_decisions=` a
  `Layouts.app`, em `live/`) passam `notification_center={@notification_center}`.
- **`assets/js/elapsed.js`** + registro em `app.js` (hook `Elapsed`).
- Nenhum Channel muda.

### `apps/pipe_maestro_protocol` — **não muda**.

### `apps/pipe_maestro_runner` — **não muda**.

## Fronteiras

- `Notifications` fica no domínio, sem nada de web; os títulos/corpos são texto puro
  e Markdown, a renderização fica no web.
- O web depende do domínio (`Notifications`, `Tasks`) como hoje.
- `protocol` e `runner` não são tocados; o runner continua dependendo só de
  `protocol`.
- Dependência nova no domínio: `Tasks`/`Jobs`/`Proposals` → `Notifications` e
  `Notifications` → schemas `Task`/`Job` e `Workspaces`. Só chamadas em runtime e uso
  de structs de schema (sem ciclo de compilação entre contextos).

## Protocolo

A mudança **não toca** `apps/pipe_maestro_protocol`, nem o formato das mensagens dos
Channels dos runners, nem `docs/specs/protocolo-runner.md`. A versão do protocolo não
sobe; runners antigos e novos se comportam exatamente como hoje. As mensagens novas
(`{:notification, n}`, `{:unread_count, c}`, `{:executions_changed, ws}`) são internas
ao control plane (PubSub entre domínio e LiveViews).

## Telas

- **Mudam**: o top bar de todas as telas do workspace (`Layouts.app`).
- **Novas**: o painel (overlay) e `NotificationLive`.
- **Petal** (conferido em `petal_components` 4.17.1): `slide_over` (`origin`,
  `max_width`, `close_on_click_away`, `close_on_escape`, `close_slide_over_target`,
  `on_close`, slot `footer`), `tabs`/`tab` (`is_active`, `number`, `phx-click`),
  `badge`, `button`/`icon_button`, `icon`, `spinner`/`skeleton`, `link`. Seguir
  `docs/guias/ui-petal.md` (tema, sem markup cru quando há componente).
- **Acessibilidade**: `aria-label` dinâmico no sino; badge com `aria-hidden` e texto
  equivalente no label; lista com `role="list"`; marcador de não lida também em texto
  (`sr-only` "não lida"); ponto pulsante respeita `prefers-reduced-motion`; foco volta ao
  sino; navegação por teclado nos itens (são links/botões).
- **`data-testid`**: `notifications-bell`, `notifications-unread-count`,
  `notifications-activity-indicator`, `notifications-panel`, `notifications-tab-active`,
  `notifications-tab-inbox`, `notifications-active-item-<task id>` (e
  `notifications-active-item-<job id>` para propostas), `notifications-item-<id>`,
  `notifications-mark-all-read`, `notifications-empty-active`,
  `notifications-empty-inbox`, `notifications-see-all`; e, para os specs:
  `notifications-close`, `notifications-filter-unread`, `notifications-filter-all`,
  `notifications-mine-toggle`, `notifications-load-more`, `notifications-page`.
- **Playwright**: `e2e/tests/notifications.spec.ts` (com cabeçalho `@flow` como os
  outros) e um `NotificationsPage` em `e2e/pages/`. Fluxo: login → sino visível →
  painel abre → "Em andamento" vazio (shot) → cria tarefa com runner real
  (`helpers/runnerProcess.ts`, como `task-pipeline.spec.ts`) → indicador e
  `notifications-active-item-<id>` aparecem → tarefa pausa/termina → badge sobe sem
  reload → aba Notificações → clicar no item navega e zera → reload mantém lida;
  "Marcar todas". Shots claro/escuro, desktop e viewport mobile, das duas abas e dos
  vazios.

## Testes

- **Domínio** (`apps/pipe_maestro/test/pipe_maestro/notifications_test.exs`):
  `list_for` (ordem, paginação por cursor, `unread`), `count_unread`, `mark_read`
  /`mark_all_read` com **escopo** (outro usuário, outro workspace → `:not_found`/0 e
  nada muda), `subscribe` recebe `{:notification, _}`/`{:unread_count, _}`,
  `active_executions` (status incluídos/excluídos, propostas, `analysis` fora,
  `mine:`), `group/1`.
- **Criação em `Tasks`** (`tasks_test.exs` ou arquivo novo
  `tasks_notifications_test.exs`): pausa → `:task_awaiting_decision` ao criador;
  sucesso/falha/cancelamento; criador = dono da decisão não duplica; dono diferente
  recebe; sem criador → admins (e não membros); membro não recebe tarefa alheia;
  ex-membro não recebe.
- **Propostas**: proposta concluída → `:proposal_ready` a quem pediu; falha não;
  `analysis` não; tarefa auto-criada não.
- **Maintenance**: lida com 31 dias sai; lida com 29 e não lida antiga ficam.
- **Web**:
  - hook: montar uma tela qualquer (ex. `UsageLive`) mostra o sino e o contador;
    `Notifications.notify_task/2` → contador sobe ao vivo; `executions_changed` →
    indicador aparece/some; mensagem alheia à central não é engolida (uma tela que
    trata `:runners_changed` continua tratando);
  - painel: abrir/fechar sem perder estado da página, abas, agrupamento, "Minhas/
    Todas", vazios, clicar marca lida e navega, "Marcar todas", "Carregar mais",
    filtro;
  - `NotificationLive`: lista, filtro via `?filtro=`, escopo (não vê de outro).
  - toast e `push_event("notify")` seguem (testes atuais de `UserAuth` continuam).
- **Playwright**: acima.

## Documentação

- **ADR** `docs/adr/0041-central-de-notificacoes.md`: persistido (caixa) × derivado
  (em andamento); destinatários e o fallback para admins; `:proposal_ready` e os
  tipos excluídos; retenção de 30 dias das lidas (não lidas ficam); tópico próprio
  (`notifications:activity`) e por que não reaproveitar `tasks:workspace` no hook;
  como acrescentar um `kind` (valor no `Ecto.Enum`, função de criação no domínio,
  ícone/cor em `kind_icon/1` com fallback — sem migração, pois a coluna é string); por
  que toast e notificação do navegador continuam (aviso imediato em tela × caixa
  persistente).
- **`docs/guias/ui-petal.md`**: seção curta "Central de notificações no shell" (o
  sino no `Layouts.app`, o attr `notification_center` que toda tela do workspace
  repassa, o painel como LiveComponent, abas sem `?aba=` por ser overlay).
- **`docs/specs/`**: não há spec de modelo de dados (só `integracoes.md`,
  `maquina-de-estados-tarefa.md`, `protocolo-runner.md`); em
  `maquina-de-estados-tarefa.md`, uma linha dizendo que pausa e fim geram
  notificação persistida, apontando para a ADR. Sem contagens na prosa.
- `AGENTS.md`: acrescentar `Notifications` à lista de contextos do domínio.

## Riscos

- **Migração**: só cria tabela; nenhum dado existente é tocado. Não há backfill (a
  caixa começa vazia).
- **Concorrência / transação**: `announce/2` roda após `Repo.update!`, fora de
  transação; se a criação falhar, a tarefa já mudou — usar `insert_all` (sem
  changeset) minimiza falhas; não envolver em transação para não segurar o lock da
  tarefa. Duplicidade: cada transição chama `announce` uma vez.
- **Carga**: `executions_changed` a cada `Tasks.notify/1` → mitigado pelo debounce e
  por uma consulta indexada (status + workspace). Verificar índice em
  `tasks(workspace_id, status)`; se faltar, incluir na migração.
- **Mensagens engolidas**: o hook só faz `{:halt, …}` nas mensagens da central;
  testado.
- **Fechar o slide-over**: o Petal empurra `close_slide_over`; com
  `close_slide_over_target` vai para o componente, sem colidir com páginas.
- **Mudança ampla em `live/`**: todas as telas passam a repassar
  `notification_center`; esquecer uma deixa o sino com zero — o attr tem default e
  um teste percorre as rotas do workspace verificando o sino.
- **Cobertura ≥ 60%** no web: o LiveComponent e a página precisam de testes LiveView
  reais (sem exclusões).
- **Dialyzer**: `Ecto.Enum` e o struct `Execution` com `@type t` explícito; specs de
  `list_for/2` com tipos de opção.
- **E2E**: depende do runner real/CLI falsa já usados em `task-pipeline.spec.ts`;
  o tempo do fluxo cresce — reaproveitar o mesmo setup.

## Ordem sugerida de implementação

1. Domínio: migração, schema, `Notifications` (+ testes de escopo e retenção).
2. Ganchos em `Tasks`, `Jobs`, `Proposals`, `Maintenance` (+ testes).
3. Web: hook, sino no layout, repasse do attr nas LiveViews, `NotificationCenter`,
   `NotificationLive`, hook JS (+ testes LiveView).
4. Playwright + `make e2e.shots` (auditoria claro/escuro, desktop/mobile).
5. ADR 0041, guia, spec da máquina de estados, `AGENTS.md`; `make ci`.
