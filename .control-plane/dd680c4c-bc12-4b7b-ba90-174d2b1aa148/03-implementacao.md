# Etapa 3 — Implementação: central de notificações no top bar

O plano (`01-plano.md`) está implementado. Os testes da etapa 2 passam e só um deles
mudou (explicado abaixo). `make ci.quick`, `make ci` (com Dialyzer) e a suíte
Playwright inteira estão verdes.

## Commits

| Commit | O que entra |
|---|---|
| `c48b6d5` | domínio: migração, `Notifications`, ganchos em `Tasks`, `Jobs`, `Proposals` e `Maintenance` |
| `b08aa63` | web: hook, sino no layout, painel, página, rota, hook JS `Elapsed`, repasse do attr nas LiveViews |
| `afafd93` | docs: ADR 0041, guia de UI, máquina de estados, `AGENTS.md` |
| `0f3b9a8` | ordem dos aliases nos testes web, pedida pelo Credo |
| `661b85a` | painel em tela cheia (blur do top bar) e badge de status em cada execução |

## O que mudou, por app

### `apps/pipe_maestro` (domínio)

- **Migração** `20261116100000_create_notifications.exs`:
  - cria a tabela `notifications`, com chaves `on_delete: :delete_all` para
    workspace, usuário, tarefa e job;
  - cria índices por `(user_id, workspace_id, read_at)`,
    `(user_id, workspace_id, inserted_at)`, `read_at`, `task_id` e `job_id`;
  - cria o índice `tasks(workspace_id, status)`, que a consulta das execuções ativas
    usa.
- **`PipeMaestro.Notifications.Notification`**: schema com `kind` em `Ecto.Enum` e
  `kinds/0`.
- **`PipeMaestro.Notifications.Execution`**: struct derivada. Tem `proposal_kind`, e
  `stage` conta a partir de 1.
- **`PipeMaestro.Notifications`**:
  - `subscribe/1` assina o tópico da pessoa e o tópico de atividade do workspace;
  - `notify_task/2` e `notify_proposal/1` criam com `insert_all` e publicam
    `{:notification, n}` e `{:unread_count, c}`;
  - `recipients_for_task/1`: criador e dono da decisão, só os que ainda são membros;
    sem nenhum, os admins;
  - `list_for/2` aceita `limit`, `before: {inserted_at, id}` e `unread`;
  - `count_unread/1`;
  - `mark_read/2` e `mark_all_read/1` fazem o escopo no `where` e publicam o novo
    contador;
  - `delete_read_before/1` serve à retenção;
  - `active_executions/2` aceita `mine:`, e `group/1` separa as execuções por status;
  - `executions_changed/1` avisa o workspace que algo mudou.
- **`Tasks`**:
  - `announce/2` chama `notify_task/2`; ele já é o único ponto de pausa e de fim,
    cancelamento incluído;
  - `notify/1` chama `executions_changed/1`.
- **`Jobs`**:
  - `insert_and_assign/1` e `notify/1` avisam `executions_changed/1` quando o job é
    proposta;
  - `finished/1` manda toda proposta que não é `analysis` para
    `Proposals.job_finished/1`.
- **`Proposals.job_finished/1`**: avisa `:proposal_ready` quando a proposta termina com
  sucesso. Não avisa para `analysis` nem para proposta de tarefa auto-aprovada que virou
  tarefa: `auto_create` agora devolve `:created` ou `:not_created`.
- **`Maintenance.run/2`**: ganha a parte `notifications`, com `:notifications_days`
  (padrão 30).

### `apps/pipe_maestro_web`

- **`PipeMaestroWeb.NotificationHooks`** (novo), encadeado em
  `UserAuth.on_mount(:require_workspace)`:
  - atribui `@notification_center` (`unread`, `active`);
  - interrompe (`{:halt, …}`) só `{:unread_count, _}`, `{:notification, _}`,
    `{:executions_changed, _}` e `:refresh_active_executions`;
  - recarrega as execuções com debounce de 300 ms;
  - as outras mensagens seguem com `{:cont, socket}`.
- **`Layouts.app/1`**:
  - novo attr `notification_center`;
  - o LiveComponent fica antes do `color_scheme_switch`;
  - o blur do header passa para um pseudo-elemento `before:` e o header sobe para
    `z-30`. Explicação em "Desvios do plano".
- **`PipeMaestroWeb.NotificationCenter`** (LiveComponent, novo):
  - **sino**: `aria-haspopup="dialog"`, `aria-label` com o total de não lidas, badge
    "9+" e ponto pulsante (`motion-reduce:hidden`);
  - **painel**: `slide_over` do Petal com abas `<.tabs>` e `<.tab link_type="button">`;
  - **Em andamento**: grupos, toggle "Minhas/Todas" e estado vazio com link para
    criar tarefa;
  - **Notificações**: filtro, "Carregar mais" (busca uma página + 1), "Marcar todas",
    "Ver todas" e "Fechar" no rodapé;
  - clicar num item marca lida e faz `push_navigate`.
- **`PipeMaestroWeb.NotificationComponents`** (novo): `notification_item/1`,
  `execution_item/1` com badge de status, `kind_style/1` com fallback, `path/2`,
  `testid/1` e `elapsed/2`.
- **`PipeMaestroWeb.NotificationLive`** (novo) e a rota
  `/w/:workspace_slug/notifications`: filtro em `?filtro=nao-lidas` na barra
  `:actions`, "Marcar todas" e "Carregar mais".
- **Todas as LiveViews do workspace** passam
  `notification_center={@notification_center}` a `Layouts.app`.
- **`assets/js/elapsed.js`** (hook `Elapsed`, registrado em `app.js`): tempo decorrido
  a cada segundo e tempo relativo a cada minuto. O servidor renderiza o primeiro
  valor.

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`

Não mudam. Nenhum Channel muda, e a versão do protocolo é a mesma. Por isso não há
tratamento de runner antigo a fazer.

### Documentação

- `docs/adr/0041-central-de-notificacoes.md`.
- `docs/guias/ui-petal.md`: nova seção "Central de notificações no shell".
- `docs/specs/maquina-de-estados-tarefa.md`: diz que a pausa e o fim geram notificação
  persistida.
- `AGENTS.md`: `Notifications` entra na lista de contextos.

## Teste corrigido

O helper `run_current/3` de `notification_center_test.exs` não mandava `"artifact"`
ao terminar o job. Sem artefato, o gate trata a etapa como não concluída e a tenta de
novo (`Engine`: "A etapa terminou sem escrever o artefato"). Assim a tarefa nunca
chegava a "etapa 2 de 2", e a asserção ao vivo não tinha como passar. O helper passou a
mandar `"artifact" => "# Artefato"`, como o helper equivalente do teste de domínio. A
asserção continua igual.

Também reordenei os aliases dos dois testes web, porque o Credo `--strict` reprovava a
ordem.

## Desvios do plano e decisões de detalhe

- **O blur do top bar.** O `backdrop-blur` do `<header>` cria um bloco de contenção para
  `position: fixed`, e o slide-over ficava preso dentro do header (visto no e2e). Tentei
  `<.portal>`, mas o `LiveViewTest` não enxerga conteúdo de `<template>`, e os testes do
  painel quebravam. A solução foi pôr o blur num pseudo-elemento `before:` do header e
  subir o header para `z-30`, para o overlay cobrir a sidebar. O visual é o mesmo.
- **Fechar.** O botão "Fechar" (`notifications-close`) fica no rodapé do slide-over e
  dispara o mesmo `hide_slide_over` do X do Petal, mais `JS.pop_focus()`. O X do Petal
  não aceita `data-testid`.
- **`data-testid="notifications-panel"`** fica num `div` dentro do slide-over. A raiz do
  Petal tem altura zero (os filhos são `fixed`), e o Playwright a dava como oculta.
- **Ponto pulsante.** Acende com tarefa ou proposta `running` ou `queued`. Uma tarefa que
  espera uma pessoa aparece em "Em andamento", mas não acende o ponto (ADR 0041,
  decisão 8).
- **Caixa do painel em lista, não em stream.** A caixa tem poucas páginas e precisa ser
  re-renderizada inteira ao "Marcar todas".
- **Título de `:proposal_ready`**: "Proposta pronta para revisão: <título da proposta>".

## Como verificar

```sh
mix test apps/pipe_maestro/test/pipe_maestro/notifications_test.exs
mix test apps/pipe_maestro_web/test/pipe_maestro_web/live/notification_center_test.exs \
         apps/pipe_maestro_web/test/pipe_maestro_web/live/notification_live_test.exs
make ci.quick > /tmp/ciq.log 2>&1; echo $?   # 0
make ci > /tmp/ci.log 2>&1; echo $?          # 0 (Dialyzer: 0 erros)
E2E_FORGEJO_PORT=4637 E2E_GITHUB_PORT=4638 make e2e.shots FILE=tests/notifications.spec.ts
```

Resultados desta execução:

| Verificação | Resultado |
|---|---|
| `pipe_maestro` | 526 testes passam |
| `pipe_maestro_web` | 478 testes passam |
| `protocol` | 104 testes passam |
| `runner` | 220 testes passam |
| `make ci.quick` | 0 |
| `make ci` | 0 |
| `make e2e.shots` | `notifications.spec.ts` passa e a suíte inteira passa (30 testes) |

As portas alternativas do Forgejo e do GitHub falsos estavam ocupadas pelo e2e de outra
worktree.

Os screenshots ficam em
`e2e/screenshots/notifications/follows-what-runs-and-keeps-what-happened-from-any-page/`.
Conferi os dois temas: painel "Em andamento" com tarefa rodando, caixa com não lida,
sino com contador e toast, página, filtro vazio e o painel a 390 px nas duas abas.

## Pendências para a próxima etapa

- Nenhuma funcional.
- Observação de processo: para desfazer um `IO.inspect` de depuração, usei
  `git checkout --` num arquivo de teste já commitado, com outras mudanças não
  commitadas na árvore. Não se perdeu nada, mas o `AGENTS.md` desaconselha isso.

## Retomada após o reinício do runner

A tentativa anterior terminou com "O runner reiniciou durante a execução". O código e
este artefato já estavam commitados. Nesta retomada, rodei o gate de novo, do zero:

| Verificação | Resultado |
|---|---|
| `make ci.quick` | 0 (104 + 526 + 478 + 220 testes, Credo sem issues) |
| `mix dialyzer` | 0 erros |
| `make e2e FILE=tests/notifications.spec.ts` | 1 passed |

Observação de ambiente: o Postgres de teste é compartilhado entre worktrees (limite de
100 conexões) e o pool de teste é `2 × schedulers` (28 nesta máquina). Com as suítes
de outras worktrees rodando ao mesmo tempo, `make ci.quick` falhou ao criar o banco com
`too_many_connections`. Passou com `ELIXIR_ERL_OPTIONS="+S 6:6" make ci.quick`, que só
reduz o pool, sem mudar nenhum teste.
