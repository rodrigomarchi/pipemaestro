# Etapa 3 — Implementação: "Os alertas do Board"

Implementei o plano sem mexer nos testes da etapa 2: nenhum foi alterado nem enfraquecido.

## O que mudou, por app

### `apps/pipe_maestro` (domínio)

`PipeMaestro.Tasks` (`lib/pipe_maestro/tasks.ex`):
- `runner_offline?/2` (pública, com `@doc` e `@spec`): diz se a tarefa está `:running`
  num runner fora do conjunto de online. `alerts/2` passou a usar essa função.
- `alerts_change_at/2` (pública, `now` padrão `DateTime.utc_now()`): o menor
  `Runners.resets_at/1` futuro entre os alertas `{:runner_near_limit, _, runner}`, ou
  `nil`. Ignora `resets_at` vencido ou ausente.
- Não há schema novo nem migração.

### `apps/pipe_maestro_web`

- `BoardLive`:
  - `load_alerts/1` saiu de `load_tasks/1`, que agora o chama.
  - `presence_diff` e `:runners_changed` rodam `load_runners/1 |> load_alerts/1`.
  - `load_alerts/1` cancela o timer anterior e agenda `:alerts_expired` para
    `alerts_change_at/1`, com teto de 24 h. Passado o teto, o Board recalcula e agenda
    de novo. O timer só existe com o socket conectado.
  - Nova cláusula `handle_info(:alerts_expired, _)`. Não há catch-all.
  - O `@moduledoc` foi atualizado.
- `TaskLive.Show`:
  - Assina `RunnerStatus` no mount conectado e mantém o assign `online`
    (`RunnerStatus.online_ids/1`), recarregado em `presence_diff` e
    `:runners_changed`.
  - Novo `<.alert color="danger" with_icon data-testid="task-runner-offline">`, exibido
    quando `Tasks.runner_offline?(@task, @online)`. Como a condição usa `@task`, o aviso
    acompanha qualquer atualização da tarefa: ele some quando a tarefa sai de `:running`.
- `RunnerStatus`: só o `@moduledoc` mudou ("e os alertas que dependem deles").

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`

Não mudaram. Como o protocolo não foi tocado, não há tratamento de runner antigo a fazer.

### Documentação

ADR 0024: o item do limite da conta agora registra que o alerta do Board some sozinho na
renovação, com um timer até o `resets_at` mais próximo e sem polling.

## Commits

- `feat(tasks): runner_offline?/2 e alerts_change_at/2`
- `feat(web): alertas do Board e aviso da tarefa acompanham o runner ao vivo`
- `docs: alerta de limite some na renovação; RunnerStatus recarrega alertas`
- `style(web): ordem dos aliases em TaskLive.Show` (corrige o Credo)

## Como verificar

```
mix test apps/pipe_maestro/test/pipe_maestro/tasks_test.exs \
  apps/pipe_maestro_web/test/pipe_maestro_web/live/board_live_test.exs \
  apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs
# Result: 57 passed / 36 passed

make ci.quick > /tmp/ciq.log 2>&1; echo $?     # 0
make e2e FILE=tests/board-alerts.spec.ts       # 1 passed
make e2e                                       # 17 passed
make e2e.shots FILE=tests/board-alerts.spec.ts # board-alertas e task-runner-offline, claro e escuro
```

Conferi as screenshots em `e2e/screenshots/board-alerts/...`:
- no Board, o card "Precisa de atenção" mostra os alertas de offline e de limite;
- na tarefa, o aviso vermelho com o nome do runner aparece abaixo dos metadados.

Os dois ficam legíveis no tema claro e no escuro, sem estouro de layout.

`make ci` completo, com Dialyzer, fica para a etapa de revisão e entrega. Os `@spec`
novos são `boolean()` e `DateTime.t() | nil`.
