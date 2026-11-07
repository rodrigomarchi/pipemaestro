# Etapa 2 — Testes que falham: central de notificações

Testes escritos antes da implementação, seguindo o plano (`01-plano.md`). Nenhum
código de produção foi tocado; nenhum stub foi criado. Todos os testes novos falham
porque `PipeMaestro.Notifications`, o schema `Notification`, o struct `Execution`,
o sino no `Layouts.app`, o painel e a rota `/w/:slug/notifications` ainda não
existem.

## Arquivos

| Arquivo | O que cobre |
|---|---|
| `apps/pipe_maestro/test/pipe_maestro/notifications_test.exs` | domínio: criação em `Tasks` (pausa, sucesso, falha, cancelamento), destinatários (criador, dono da decisão sem duplicar, admins quando não há criador, ex-membro fora, membro não recebe tarefa alheia), `:proposal_ready` (sucesso sim; falha, `analysis` e tarefa auto-aprovada não), PubSub (`{:notification, n}`, `{:unread_count, c}`, `{:executions_changed, ws}`), `list_for/2` (ordem, `limit`, cursor `before`, `unread`), `count_unread/1`, `mark_read/2` e `mark_all_read/1` com escopo, `active_executions/2` (tarefas nos três status, propostas, `analysis` fora, `mine:`), `group/1`, retenção via `Maintenance.run/1` |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/notification_center_test.exs` | hook + sino + painel: sino e contador em **todas** as rotas do workspace (pega LiveView que esqueça de repassar `notification_center`), `aria-haspopup`/`aria-label`, "9+", contador sobe ao vivo com toast e `push_event("notify")` intactos, ponto pulsante aparece/some, mensagens da página não são engolidas, abrir/fechar, aba "Em andamento" agrupada com etapa/runner/criador/`Elapsed` e atualizada ao vivo, "Minhas/Todas", proposta em andamento, caixa (clique navega e marca lida, proposta abre a proposta, "Marcar todas", "Carregar mais", filtro, vazio, "Ver todas", notificação nova com o painel aberto) |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/notification_live_test.exs` | página `NotificationLive`: lista só do usuário e do workspace, corpo em Markdown, filtro por `?filtro=nao-lidas` (sobrevive ao reload), clique navega e marca lida, "Marcar todas", "Carregar mais", vazio |
| `e2e/pages/NotificationsPage.ts` | Page Object da central (sino, painel, abas, itens, página) |
| `e2e/tests/notifications.spec.ts` | fluxos A–E com runner real e `fake_claude` (`[lento] [bloqueio]` para ver a tarefa rodando e depois pausar), shots claro/escuro, desktop e 390 px |

## Contrato que os testes fixam (para a implementação)

Decisões de detalhe que o plano deixava em aberto e que os testes agora fixam:

- **Schema** `PipeMaestro.Notifications.Notification` com `workspace_id`, `user_id`,
  `kind` (`Ecto.Enum`), `title`, `body`, `task_id`, `job_id`, `read_at`,
  `inserted_at`. Os testes inserem linhas direto (`struct/2` + `Repo.insert!`) com
  `inserted_at`/`read_at` explícitos.
- **Títulos**: `"<título> aguarda decisão"`, `"<título> foi concluída"`,
  `"<título> falhou"`, `"<título> foi cancelada"` (os mesmos do toast). O corpo da
  pausa contém o `decision_reason`.
- `Notifications.notify_task(task, kind)` recebe o `kind` do evento de tarefa
  (`:awaiting | :succeeded | :failed | :canceled`), como `announce/2`.
- `list_for(scope, opts)` com `limit:`, `before: {inserted_at, id}` e `unread: true`;
  ordem por `inserted_at` desc. Notificações do mesmo segundo não têm ordem garantida
  entre si (por isso os testes comparam os `kind` ordenados).
- `mark_read/2` → `{:ok, %Notification{read_at: %DateTime{}}}` ou
  `{:error, :not_found}` (outro usuário, outro workspace, id inexistente);
  `mark_all_read/1` → `{count, _}`; ambos publicam `{:unread_count, n}`.
- `subscribe(scope)` recebe `{:notification, n}`, `{:unread_count, c}` e
  `{:executions_changed, workspace_id}` (este também quando uma proposta é pedida).
- `%Execution{}` com `id`, `type` (`:task | :proposal`), `title`, `status`, `stage`
  (**contado a partir de 1**: "etapa 1 de 2"), `stage_count`, `runner_name`,
  `started_at`, `creator_id`, `creator_name` e **`proposal_kind`** (ex.
  `"pipeline"`, para "proposta · pipeline"; campo novo em relação ao plano).
- `group/1` → `%{running: [...], awaiting_decision: [...], queued: [...]}`.
- `Maintenance.run/1` devolve a chave `notifications` (lidas há mais de 30 dias).
- **`data-testid`** (além dos do plano):
  - item da caixa: **`notifications-item-<id da tarefa ou do job>-<kind>`**, com o
    `kind` em kebab-case (`task-awaiting-decision`, `task-succeeded`, `task-failed`,
    `task-canceled`, `proposal-ready`). O plano dizia `notifications-item-<id>`, mas
    o id da notificação não é conhecido pelo spec; a regra do `e2e/README.md` pede
    chave natural, e a tarefa/job + tipo é o que o spec conhece;
  - atributo `data-unread="true" | "false"` no item (marcador de não lida);
  - grupos de "Em andamento": `notifications-group-running`,
    `notifications-group-awaiting`, `notifications-group-queued`;
  - `notifications-page` na raiz da página.
- O tempo decorrido é um elemento com `phx-hook="Elapsed"` e `data-since`.
- "Minhas/Todas" começa em **Todas**; o filtro da caixa começa em **Todas**.
- Página: `?filtro=nao-lidas` para não lidas; "Todas" volta para a URL sem query.
- O texto do grupo da tarefa ativa contém "Rodando"; o vazio da aba ativa contém
  "Nada rodando agora".

## Resultado: falham pelo motivo certo

`mix format` rodado. Comandos a partir da raiz.

### Domínio — `mix test apps/pipe_maestro/test/pipe_maestro/notifications_test.exs`

```
Result: 0/19 passed
Failed: 19 tests
```

Todas por módulo inexistente, por exemplo:

```
 15) test a task's pause and end reach its people a pause notifies the creator, once, with the reason
     ** (UndefinedFunctionError) function PipeMaestro.Notifications.list_for/1 is undefined
        (module PipeMaestro.Notifications is not available)

 19) test retention read notifications older than 30 days go; recent and unread ones stay
     ** (UndefinedFunctionError) function PipeMaestro.Notifications.Notification.__struct__/0 is undefined
        (module PipeMaestro.Notifications.Notification is not available)
```

Os demais acusam `subscribe/1`, `active_executions/1,2`, `count_unread/1` — sempre
`UndefinedFunctionError` do contexto ou do schema, que é o esperado antes da
implementação. (Os padrões de struct foram escritos como `%{__struct__: Notification}`:
no Elixir 1.20 um `%Notification{}` em padrão com o módulo inexistente vira erro de
tipagem que aborta a execução no meio; assim todos os 19 rodam e falham.)

### Web — `mix test apps/pipe_maestro_web/test/pipe_maestro_web/live/notification_center_test.exs apps/pipe_maestro_web/test/pipe_maestro_web/live/notification_live_test.exs`

```
Result: 0/20 passed
Failed: 20 tests
```

Três motivos, todos esperados:

- **sino ausente** no top bar:
  ```
  ** (ArgumentError) expected selector "[data-testid=notifications-bell]" to return a single element, but got none
  ```
  e asserções `Expected truthy, got false` em
  `has_element?(view, "[data-testid=notifications-unread-count]", "1")`,
  `[data-testid=notifications-bell][aria-haspopup=dialog]` e
  `[data-testid=notifications-activity-indicator]`;
- **schema inexistente** nos testes que gravam notificações:
  `UndefinedFunctionError ... Notification.__struct__/0 is undefined`;
- **rota inexistente** (`/w/:slug/notifications`): `no route path for
  PipeMaestroWeb.Router matches "/w/#{slug}/notifications"` e
  `FunctionClauseError ... connect_from_static_token/3` ao montar.

### Suíte existente

`mix test` (todos os apps):

```
pipe_maestro_protocol  Result: 104 passed
pipe_maestro           Result: 507/526 passed — Failed: 19 tests  (todos PipeMaestro.NotificationsTest)
pipe_maestro_web       Result: 458/478 passed — Failed: 20 tests  (15 NotificationCenterTest + 5 NotificationLiveTest)
pipe_maestro_runner    Result: 220 passed
```

Nenhum teste que já existia falha.

### Playwright

- `make e2e.typecheck`: **passa** (spec e Page Object compilam).
- `E2E_FORGEJO_PORT=4637 E2E_GITHUB_PORT=4638 make e2e FILE=tests/notifications.spec.ts`
  (as portas padrão do Forgejo/GitHub falsos estavam ocupadas pelo e2e de outra
  worktree): **falha no primeiro passo do fluxo A**, pelo motivo certo:

  ```
  ✘ tests/notifications.spec.ts:30:7 › Notification center › follows what runs and keeps what happened, from any page
    Error: expect(locator).toBeVisible() failed
    Locator: getByTestId('notifications-bell')
    Expected: visible
    Error: element(s) not found
  ```

## Observações para a implementação

- O spec usa `Prompt único` (uma etapa: "etapa 1 de 1") e o marcador
  `[lento] [bloqueio]` do `fake_claude`: 30 s rodando, depois pausa — dá tempo de ver
  o item em "Em andamento" e, sem recarregar, o contador subir.
- O teste "the page's own messages still reach it" garante que o hook só interrompe
  (`{:halt, …}`) as mensagens da central; `RunnersLive` continua tratando
  `:runners_changed`.
- O teste do debounce usa espera ativa curta (`eventually/2`, até 1 s), compatível
  com os 300 ms do plano.
