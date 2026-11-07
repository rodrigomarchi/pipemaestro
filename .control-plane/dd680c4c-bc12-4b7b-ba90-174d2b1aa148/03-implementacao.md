# Etapa 3 — Implementação: central de notificações no top bar

Implementa o plano de `01-plano.md` até os testes de `02-testes.md` passarem, sem
alterar o que eles verificam.

## Tentativa anterior

A tentativa anterior foi interrompida porque o runner reiniciou: o domínio, a web e
a documentação já estavam commitados, mas três ajustes visuais do painel ficaram
fora do commit. Nesta tentativa eles foram revisados, testados e commitados
(`661b85a`), e o gate rodou até o fim.

## Commits da etapa

| Commit | O quê |
|---|---|
| `c48b6d5` feat(notificacoes): caixa persistente e execuções ativas no domínio | contexto `PipeMaestro.Notifications`, schema `Notification`, struct `Execution`, migração `create_notifications`, ganchos em `Tasks`, `Proposals`, `Jobs` e `Maintenance` |
| `b08aa63` feat(notificacoes): sino, painel e página de notificações no top bar | `NotificationHooks` (on_mount), `NotificationCenter` (LiveComponent), `NotificationComponents`, `NotificationLive` (`/w/:slug/notifications`), sino em `Layouts.app`, repasse do attr nas LiveViews, hook JS `Elapsed` |
| `afafd93` docs(notificacoes) | ADR 0041, guia `ui-petal.md`, `maquina-de-estados-tarefa.md`, `AGENTS.md` (contexto `Notifications`) |
| `0f3b9a8` test(notificacoes) | ordem dos aliases nos testes, pedida pelo Credo (nenhuma asserção mudou) |
| `661b85a` fix(notificacoes) | painel fora do blur do top bar; badge de status em cada execução ativa |

## O que mudou por app

### `apps/pipe_maestro` (domínio)

- `PipeMaestro.Notifications`: caixa persistente por pessoa (criar, listar
  paginado, filtrar não lidas, contar, marcar lida, marcar todas), execuções ativas do
  workspace (tarefas rodando, aguardando decisão, na fila, e propostas em andamento),
  e o broadcast `{:executions_changed, ws}` em `notifications:activity:<ws>` e
  `{:notification, n}` no tópico de cada pessoa.
- `Tasks`/`Proposals`/`Jobs` avisam a central quando uma execução muda e gravam a
  notificação ao criador quando a tarefa pausa, conclui, falha ou é cancelada, ou
  quando a proposta fica pronta.
- `Maintenance` remove notificações antigas.

### `apps/pipe_maestro_web`

- `NotificationHooks`: no `on_mount(:require_workspace)`, assina os tópicos da central,
  mantém contador de não lidas e execuções ativas (com debounce de 300 ms) e só
  interrompe (`{:halt, …}`) as mensagens da própria central; o resto chega à LiveView.
- Sino no top bar de `Layouts.app` (contador "9+", ponto pulsante com execuções
  ativas), painel slide-over com as abas "Em andamento" e "Notificações", e a página
  `/w/:slug/notifications`.
- Header do layout: o `backdrop-blur` saiu do `<header>` para um pseudo-elemento
  (`before:`). Um `backdrop-filter` no header cria um containing block, e o slide-over
  `fixed` ficava preso aos 64 px do top bar. O `data-testid="notifications-panel"` foi
  para um `div` interno, porque o `slide_over` do Petal não repassa atributos
  arbitrários.
- Cada execução ativa mostra um badge com o status (Rodando, Aguardando decisão, Na
  fila).

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`

Não mudam. O protocolo não é tocado, então não há tratamento de runner antigo.

## Testes

Nenhum teste da etapa 2 foi enfraquecido. A única mudança neles é a ordem dos aliases
pedida pelo Credo (`0f3b9a8`).

## Como verificar

```sh
mix test apps/pipe_maestro/test/pipe_maestro/notifications_test.exs
cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/live/notification_center_test.exs test/pipe_maestro_web/live/notification_live_test.exs
make ci.quick > /tmp/ciq.log 2>&1; echo $?
mix dialyzer
E2E_FORGEJO_PORT=4637 E2E_GITHUB_PORT=4638 make e2e FILE=tests/notifications.spec.ts
```

## Resultados

- `make ci.quick`: **exit 0**. protocol 104, domínio 526, web 478, runner 220 testes,
  todos passando; Credo sem issues; cobertura acima de 60% em todos os apps.
- `mix dialyzer`: **0 erros**.
- `make e2e FILE=tests/notifications.spec.ts`: **1 passed** (fluxo completo do sino,
  painel, contador ao vivo, marcar lida e página de notificações).
- Observação de ambiente: o Postgres de teste é compartilhado entre worktrees (limite
  de 100 conexões) e o pool de teste é `2 × schedulers` (28 aqui). Com outras suítes
  rodando ao mesmo tempo, a criação do banco falhou com `too_many_connections`. O gate
  passou com `ELIXIR_ERL_OPTIONS="+S 6:6" make ci.quick`, que só reduz o pool, sem
  mudar nenhum teste.
