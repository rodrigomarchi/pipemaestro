# Etapa 4 — Revisão de convenções

Revisado o diff contra `origin/main` (domínio, web, JS, e2e, docs). `make ci.quick` passa (exit 0).
Nenhuma correção de código foi necessária.

## Conferido

- **Plano cumprido**: contexto `Notifications` (inbox, execuções ativas, PubSub), ganchos em
  `Tasks`/`Jobs`/`Proposals`/`Maintenance`, hook web, sino e painel, página `/notifications`,
  hook JS `Elapsed`, ADR 0041. Critérios de aceite têm testes de domínio, LiveView
  (`notification_center_test`, `notification_live_test`) e e2e (`notifications.spec.ts`).
- **`@spec`/`@moduledoc`** em todos os módulos e funções públicas novas.
- **LiveViews finas**: só estado de UI (aba, filtro, paginação); regra de destinatários, escopo e
  contagem ficam em `Notifications`.
- **Petal**: slide-over, tabs, button, badge, card; Tailwind cru só onde o Petal não cobre.
- **`data-testid`** em tudo o que o Page Object toca; segue o precedente existente de ids por
  registro (`task-link-<id>`).
- **Handlers**: o `handle_info` catch-all do hook devolve `{:cont, socket}` (não engole); só as
  mensagens da própria central são interrompidas.
- **Fronteiras do umbrella**: protocolo e runner intocados; domínio sem web.
- **Cobertura**: nenhuma exclusão nova. **Contagens na prosa**: nenhuma.
- **Comentários** descrevem o código, não a mudança.

## Observações (sem ação)

- `fetch/2` e `@page` se repetem em `NotificationCenter` e `NotificationLive`; pequeno, sem
  divergência hoje. Candidato a mover para `Notifications` se uma terceira tela aparecer.
- A página `/notifications` não recebe notificações ao vivo na lista (o contador do sino sim).
