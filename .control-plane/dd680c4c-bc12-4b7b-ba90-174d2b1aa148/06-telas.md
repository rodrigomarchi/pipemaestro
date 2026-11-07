# Telas (e2e)

A tarefa mudou telas: o painel de notificações no top bar (`notification_center.ex`, `notification_components.ex`) e a página de notificações (`notification_live.ex`).

## Execução
- `make e2e`: 30 specs passaram (exit 0), incluindo `tests/notifications.spec.ts`.
- `make e2e.shots FILE=tests/notifications.spec.ts`: na primeira rodada falhou (spec frágil, abaixo); após o ajuste passou, com screenshots clara e `-dark` (copiadas para `telas/` dos arquivos da tarefa).

## Telas e estados conferidos (claro e escuro)
- Painel, aba "Em andamento": vazio ("Nada rodando agora" com link para criar tarefa) e com uma execução rodando (status, etapa, runner, autor, tempo).
- Painel, aba "Notificações": item não lido (ponto e fundo destacados, "Marcar todas como lidas") e filtros Todas/Não lidas.
- Página de notificações: lista com itens lidos e não lidos, e estado vazio de "Não lidas".
- Painel em viewport estreita (390px), nas duas abas: sem texto cortado nem sobreposição.
- Contraste, alinhamento e consistência com as telas vizinhas e `docs/guias/ui-petal.md` adequados.

## Ajustes
- `e2e/tests/notifications.spec.ts` e `e2e/pages/NotificationsPage.ts`: no passo de tela estreita, o spec estava na página de notificações, onde o painel e a lista repetem o mesmo `data-testid` de item (violação de strict mode). Criado `panelItem`, que escopa o item ao painel. Nenhuma mudança de código da aplicação.
