# Telas (e2e)

A tarefa mudou telas: o painel de notificações no top bar (`notification_center.ex`, `notification_components.ex`) e a página `/notificações` (`notification_live.ex`).

## Execução
- `make e2e`: 30 specs passaram (exit 0), incluindo `tests/notifications.spec.ts`.
- `make e2e.shots FILE=tests/notifications.spec.ts`: screenshots geradas nas versões clara e `-dark`.

## Telas e estados conferidos (claro e escuro)
- Painel, aba "Em andamento": vazio ("Nada rodando agora" com link para criar tarefa) e com uma execução rodando (status, etapa, runner, autor, tempo).
- Painel, aba "Notificações": item não lido (ponto e fundo destacados, "Marcar todas como lidas") e filtros Todas/Não lidas.
- Painel em viewport estreita: sem texto cortado nem sobreposição.
- Página de notificações: lista com itens lidos e não lidos, e estado vazio de "Não lidas".
- Contraste, alinhamento e consistência com as telas vizinhas e com `docs/guias/ui-petal.md` estão adequados.

## Ajustes
Nenhum. Nenhuma alteração de código foi necessária nesta etapa.
