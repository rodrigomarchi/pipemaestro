# Etapa 7 — Documentação e resumo: "Os alertas do Board"

## Documentação

- **ADR nova: não precisa.** A decisão de mostrar esses alertas já está nas ADRs 0012 e 0024. A tarefa cumpre o "atualiza ao vivo" que o Board já prometia.
- **ADR atualizada:** `docs/adr/0024-resumo-da-execucao-e-metricas-do-agente.md`. O item do limite da conta registra que o alerta some sozinho na renovação, com um timer até o `resets_at` mais próximo e sem polling. O commit é `d79eeba`. O índice em `docs/README.md` não muda, porque não há ADR nova.
- **Specs e guias:** nenhum muda. O protocolo, a máquina de estados e os guias de UI e Phoenix ficam como estão. O `e2e/README.md` já cobre o padrão de `data-testid` usado.
- `@moduledoc` de `BoardLive` e `RunnerStatus`, e `@doc` das funções novas de `Tasks`, foram atualizados junto com o código.

## Resumo para quem vai revisar

### O que mudou e por quê

O Board não reagia a tudo que muda o estado de um runner. O limite da conta só aparecia depois de recarregar a tela, e o alerta de limite nunca sumia sozinho. A tela da tarefa não dizia que o runner estava offline.

- **`apps/pipe_maestro` (domínio):** em `PipeMaestro.Tasks`, `runner_offline?/2` concentra a regra "tarefa `:running` num runner fora do conjunto de online", e `alerts/2` passa a usá-la. `alerts_change_at/2` devolve o próximo instante em que um alerta de limite vence por tempo. Sem schema e sem migração.
- **`apps/pipe_maestro_web`:**
  - `BoardLive`: `presence_diff` e `:runners_changed` recarregam só os alertas (`load_alerts/1`), não o `load_tasks/1` completo. Um timer `:alerts_expired` até o `resets_at` mais próximo, com teto de 24 h, faz o alerta de limite sumir na renovação.
  - `TaskLive.Show`: assina `RunnerStatus` e mostra o aviso `task-runner-offline` (`<.alert>` do Petal) enquanto a tarefa está `:running` com o runner offline.
  - `RunnerStatus`: só o `@moduledoc`.
- **`apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`:** não mudam.
- **e2e:** novo `e2e/tests/board-alerts.spec.ts`, com métodos novos em `AppPage` e `TasksPage`.

### Protocolo

Não mudou. `docs/specs/protocolo-runner.md` e a versão do protocolo ficam como estão. Os sinais usados (`presence_diff`, `:runners_changed`) são PubSub interno do control plane. Runners antigos não são afetados: o que eles já mandam (`job:event` do tipo `rate_limit`, join do canal) é o que dispara os sinais.

### Riscos e o que olhar com mais atenção

- **Timer do Board:** `load_alerts/1` cancela o timer anterior antes de agendar outro, e o timer só existe com o socket conectado. Confira se não há caminho que acumule timers.
- **Custo:** `:runners_changed` também chega em `worktree:usage` e `runner:directories`, e cada um roda a consulta de `alerts/2`. É uma consulta só, e o `presence_diff` ficou mais barato por não chamar mais `load_tasks/1`.
- **Fora do escopo:** o instante em que uma decisão passa a ficar atrasada não gera timer. Esse alerta continua dependendo de um evento ou de recarga.
- **Diff contra `main`:** ele inclui o commit `9083e9a` (entrega em PR no Forgejo, ADR 0027, mudanças no runner), que já estava na base da branch e não faz parte desta tarefa.
- **Dialyzer:** o `make ci` completo foi registrado na etapa 5. Os `@spec` novos são `boolean()` e `DateTime.t() | nil`.

### Como verificar

```
make ci > /tmp/ci.log 2>&1; echo $?
make e2e FILE=tests/board-alerts.spec.ts
make e2e.shots FILE=tests/board-alerts.spec.ts   # claro e escuro
```

Testes focados:

- `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs`
- `apps/pipe_maestro_web/test/pipe_maestro_web/live/board_live_test.exs`
- `apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs`

Passos manuais:

1. Com um runner online, crie uma tarefa cujo prompt tenha `[lento] [limite]` e abra o Board. O card "Precisa de atenção" mostra o alerta de limite.
2. Pare o runner, sem recarregar. O alerta "runner offline" aparece.
3. Abra a tarefa. O aviso vermelho "A tarefa está parada: o runner … está offline." aparece.
4. Suba o runner de novo. Os dois avisos somem.
