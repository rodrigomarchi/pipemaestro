# Etapa 4 — Revisão de convenções: "Os alertas do Board"

Revisei o diff da tarefa (`git diff $(git merge-base HEAD main)`). Não encontrei nada a corrigir; não houve commit de código nesta etapa.

## Plano e critérios de aceite
- Domínio: `Tasks.runner_offline?/2` e `Tasks.alerts_change_at/2` existem, e `alerts/2` usa a primeira.
- Board: `presence_diff` e `:runners_changed` recarregam só os alertas (`load_alerts/1`), com um timer `:alerts_expired` até o `resets_at` mais próximo e teto de 24 h.
- Tarefa: `TaskLive.Show` assina `RunnerStatus` e mostra `task-runner-offline`.
- Critérios 1 a 5 têm teste: domínio (`tasks_test.exs`), LiveView (`board_live_test.exs`, `task_live_test.exs`) e e2e (`board-alerts.spec.ts`).
- Critério 6: `make ci.quick` passou (exit 0). O Dialyzer completo (`make ci`) não rodei nesta etapa.

## Convenções
- `@spec` e `@doc` nas funções públicas novas; sem módulo novo, então sem `@moduledoc` pendente.
- LiveViews finas: a regra de "runner offline" e o instante de expiração ficam em `Tasks`.
- Aviso com `<.alert>` do Petal, sem Tailwind cru. `data-testid` em tudo que os testes tocam (`board-alert-*`, `task-runner-offline`), no padrão de `e2e/README.md`.
- Sem `handle_info` catch-all. Cada mensagem nova tem cláusula própria.
- Comentários descrevem o código. Sem contagens na prosa.
- Nenhuma dependência nova cruzando fronteira do umbrella. Protocolo e runner não mudaram. Nenhuma exclusão de cobertura.

## Observação
O diff contra `main` inclui o commit `9083e9a` (entrega em PR no Forgejo, ADR 0027, mudanças no runner). Ele já estava na base da branch e não faz parte desta tarefa. Não o revisei nem o alterei.
