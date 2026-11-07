# Documentação e resumo

## O que mudou e por quê

### `apps/pipe_maestro_web`
O Board do workspace (`/w/:slug`) deixou de empilhar tudo numa página. Agora tem abas por `?aba=`,
no mesmo padrão do `RunnerLive`: Visão geral (padrão), Tarefas, Decisões, Atividade e Executores.
Um valor desconhecido de `aba` cai na Visão geral.
- `live/board_live.ex` ficou fina: navega pelas abas, lê os filtros do kanban da URL (compartilháveis e
  sobrevivem a reload) e carrega os dados por aba.
- Um módulo por aba em `live/board_live/` (`*_tab.ex`).
- Contadores nas abas, ao vivo: alertas (Visão geral), decisões pendentes (via `@pending_decisions`) e
  `online/total` (Executores).
- Os testids existentes foram mantidos, cada um na sua aba. Os novos são `board-tabs`, `board-tab-<id>`,
  `board-tab-count-<id>` e `board-overview-*`.
- E2E: `e2e/pages/AppPage.ts` e os specs foram ajustados, com um passo que percorre as abas e tira `shot` de cada uma.

### `apps/pipe_maestro` (domínio) e `apps/pipe_maestro_protocol`
Não mudaram.

### `apps/pipe_maestro_runner`
A etapa de CI incluiu `147ed64` (`fix(runner): remove a credencial do job antes de reportar o término`).
Não faz parte da divisão do Board; foi corrigido na etapa de CI. Vale olhar à parte no PR.

## Protocolo
Não mudou. `docs/specs/protocolo-runner.md` segue igual e a versão não sobe. Runners antigos não são afetados.

## ADR
Nenhuma. O padrão de abas por `?aba=` já existia no `RunnerLive` (ADR 0039); aqui só é reaplicado.

## Documentos atualizados
- `docs/guias/instalacao.md`: o alerta de runner aparece "na Visão geral do Board".
- Specs, guias de UI e Phoenix, `e2e/README.md` e roadmap: sem mudança necessária.

## Riscos e o que olhar com mais atenção
- Runners e alertas são recarregados em todo evento, para os contadores valerem em qualquer aba.
  Já a lista de tarefas só é recarregada nas abas que a usam.
- `push_patch` a cada mudança de filtro (`phx-change`). Confira que o form reflete a URL.
- O contador de decisões depende do hook `follow_pending_decisions` em `UserAuth`.
- Dois testes foram corrigidos, e a razão está em `03-implementacao.md`: o alerta de offline só vale
  para tarefa `:running`, e o seletor `option[value=...]` precisa de aspas.
- Sem migrações nem dados.

## Como verificar
- `make ci > /tmp/ci.log 2>&1; echo $?` (esperado `0`).
- `make e2e` e `make e2e.shots`. Para um spec só: `make e2e FILE=e2e/tests/task-pipeline.spec.ts`.
- Teste LiveView: `cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/live/board_live_test.exs`.
- Passos manuais em `/w/<slug>`:
  1. Abre na Visão geral, sem kanban nem tabela de runners.
  2. Clique em cada aba: a URL muda para `?aba=…` e a aba ativa fica marcada.
  3. `?aba=xyz` mostra a Visão geral.
  4. Em Tarefas, escolha um filtro, recarregue e veja que ele continua.
  5. Derrube um runner com tarefa em execução e veja o contador da Visão geral e o `online/total`.
  6. Em largura estreita (390 px), a barra de abas rola na horizontal.
