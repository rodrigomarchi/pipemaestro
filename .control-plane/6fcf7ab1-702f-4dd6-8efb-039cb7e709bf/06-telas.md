# Telas (e2e)

A tarefa mudou telas (`runner_channel`, `task_components`, `runner_live/log_tab`, `task_live/show`,
`pipeline_diagram`) e o e2e (`e2e/pages/TasksPage.ts`, `e2e/tests/runner-restart.spec.ts`).

## Suíte e2e

- `make e2e`: 30 passaram, exit 0.
- Falha da tentativa anterior: o runner reiniciou durante a execução. Nesta rodada, a
  causa observada foi a colisão de recursos compartilhados: o log `/tmp/e2e.log` e as portas
  4013/4014 dos fakes são usados por outra execução ao mesmo tempo (`EADDRINUSE`). A
  suíte rodou com log próprio e `E2E_FORGEJO_PORT=4713 E2E_GITHUB_PORT=4714`. Não houve
  mudança de código.

## Screenshots conferidas (`make e2e.shots FILE=tests/runner-restart.spec.ts`), claro e dark

- Tarefa com etapa perdida: a tentativa 1 aparece como "Perdida (runner)" com o motivo
  em âmbar, seguida de "Tentativa 1 · de novo (1)" executando ao vivo, sem gastar tentativa.
  O diagrama mostra a etapa "Executar" em execução. Contraste, alinhamento e textos sem cortes.
- Executor, aba Eventos e logs, filtro Conexão: evento "job perdido" com aviso, e log do
  runner com duas conexões (antes e depois do reinício). Legível nos dois temas, coerente
  com as telas vizinhas.

Nada precisou de ajuste visual.
