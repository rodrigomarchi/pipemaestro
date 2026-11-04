# Telas (e2e)

A tarefa mudou telas: `BoardLive`, `TaskLive.Show`, `RunnerStatus`, mais `AppPage`/`TasksPage` e o spec `board-alerts.spec.ts` no e2e.

## Resultado
- `make e2e`: exit 0, todos os specs passaram, incluindo `board-alerts.spec.ts`.
- `make e2e.shots FILE=tests/board-alerts.spec.ts`: exit 0. Conferi as screenshots clara e `-dark`.

## Telas e estados conferidos
- **Board com alertas** (`02-board-alertas`): cartão "Precisa de atenção" com os dois alertas (runner offline e conta perto do limite), ícones e textos legíveis, alinhado aos cartões vizinhos.
- **Tarefa com runner offline** (`03-task-runner-offline`): aviso vermelho com o texto "A tarefa está parada: o runner … está offline."
- **Pedido de conexão do runner** (`01-runner-request`): sem mudança visual.

Em claro e escuro: contraste bom, sem texto cortado, consistente com `docs/guias/ui-petal.md`.

## Ajustes
Nenhum. Não houve mudança de código nesta etapa, nem commits.
