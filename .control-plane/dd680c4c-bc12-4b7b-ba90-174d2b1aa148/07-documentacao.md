# Etapa 7 — Documentação e resumo

## Documentos

- **ADR nova**: [0041 — Central de notificações no top bar](../../docs/adr/0041-central-de-notificacoes.md) (escrita na implementação). Nenhuma ADR anterior foi alterada.
- Índice `docs/README.md`: entradas 0040 (que faltava) e 0041.
- `docs/guias/ui-petal.md`: seção "Central de notificações no shell" (repasse de `notification_center` a `Layouts.app`, painel, itens).
- `docs/specs/maquina-de-estados-tarefa.md`: pausa e fim guardam uma notificação na caixa.
- `docs/plano/03-roadmap-orquestrador.md`: item de notificações aponta para a ADR 0041.
- `AGENTS.md`: `Notifications` na tabela do umbrella.
- `e2e/README.md`: sem mudança (a spec nova segue as convenções existentes).

## Resumo para quem revisa

### O que mudou e por quê
Quem usa o workspace só via o aviso de pausa ou fim se estivesse numa tela aberta; o aviso era efêmero. Agora há um sino no top bar, em toda tela do workspace, com as não lidas e as execuções ao vivo.

- **`apps/pipe_maestro` (domínio)**: contexto `Notifications` (caixa por pessoa, execuções ativas, PubSub), migração `create_notifications`, ganchos em `Tasks`, `Jobs`, `Proposals` e `Maintenance` (remove lidas com mais de 30 dias). Destinatários: criador e dono da decisão; sem eles, os admins.
- **`apps/pipe_maestro_web`**: hook em `on_mount(:require_workspace)`, sino no `Layouts.app`, painel (`NotificationCenter`, slide-over do Petal com as abas "Em andamento" e "Notificações"), página `/w/:slug/notifications`, hook JS `Elapsed`. Toast e notificação do navegador continuam.
- **`apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`**: sem mudança.

### Protocolo
Não mudou. Versão e `docs/specs/protocolo-runner.md` intactos; runners antigos e novos se comportam como antes. As mensagens novas de PubSub são internas ao control plane.

### Riscos e onde olhar
- Migração nova (tabela e índice em `tasks(workspace_id, status)`); confira em produção o tempo do índice.
- O hook interrompe só as mensagens da própria central; qualquer outra segue com `{:cont, socket}`. Vale conferir que nenhuma LiveView do workspace deixou de repassar `notification_center` a `Layouts.app`.
- `Proposals.job_finished/1`: proposta de tarefa auto-aprovada não notifica; `analysis` também não.
- A página `/notifications` não atualiza a lista ao vivo (só o contador do sino).
- `fetch/2` e `@page` duplicados entre `NotificationCenter` e `NotificationLive`; candidato a subir para `Notifications` se surgir uma terceira tela.

### Como verificar
- `make ci > log 2>&1; echo $?` (verde na etapa 5, com Dialyzer).
- `make e2e FILE=tests/notifications.spec.ts` e `make e2e` completo (verde na etapa 6).
- `make e2e.shots FILE=tests/notifications.spec.ts` para as telas claras e escuras.
- Manual: rodar uma tarefa e, em outra tela, ver o indicador e o item em "Em andamento"; ao pausar ou terminar, o badge sobe sem reload; clicar no item navega e marca lida; "Marcar todas como lidas" zera o badge; o reload mantém o estado.
