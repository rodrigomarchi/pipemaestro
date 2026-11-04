# Etapa 2 — Testes que falham: "Os alertas do Board"

Só escrevi testes. Nenhum código de produção mudou e não há stubs. As funções novas do
domínio falham por `UndefinedFunctionError`, e as telas falham por asserção.

## Testes escritos

### `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs` (describe "the task's budget")

| Teste | Critério | Resultado hoje |
|---|---|---|
| `runner_offline?: a running task whose runner is not online` | regra de domínio de `runner_offline?/2`: `:running` fora do conjunto → `true`, dentro → `false`, `:awaiting_decision` → `false` | **falha** (`UndefinedFunctionError`) |
| `alerts_change_at: the earliest future reset of a runner near its limit` | `nil` sem alerta de limite; o menor `resets_at` futuro, em Unix ou ISO 8601; ignora `resets_at` passado ou ausente | **falha** (`UndefinedFunctionError`) |

### `apps/pipe_maestro_web/test/pipe_maestro_web/live/board_live_test.exs` (describe "with tasks")

| Teste | Critério | Resultado hoje |
|---|---|---|
| `the offline alert comes and goes with the runner's presence, live` | 1 | **passa**: o `presence_diff` já chama `load_tasks/1`. Fica como regressão para quando `presence_diff` passar a chamar só `load_alerts/1` |
| `the limit alert shows as soon as a rate_limit is recorded, live` | 2 | **falha** (asserção) |
| `the limit alert goes away by itself when the limit resets` | 3 (`resets_at` 2 s à frente, sem evento; `eventually` com até 5 s) | **falha** (asserção) |

Acrescentei `eventually/1`, igual ao de `runners_live_test.exs`, e os aliases `Runners` e
`RunnerStatus`.

### `apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs` (describe "show")

| Teste | Critério | Resultado hoje |
|---|---|---|
| `a running task warns while its runner is offline, live` | 4 | **falha** (asserção) |
| `a task awaiting a decision does not warn about its runner` | 4, caso negativo | passa (o aviso ainda não existe); serve de guarda para a implementação |

Acrescentei `eventually/1`.

### e2e: `e2e/tests/board-alerts.spec.ts` (critério 5)

Cabeçalho `@section Tarefas e pipelines` com os fluxos A e B. O fluxo: operador cria o
workspace e o membro, o runner real é aprovado e iniciado, são criados os pipelines
prontos, o **Board fica aberto numa aba própria** e a tarefa "Prompt único" com
`[lento] [limite]` começa na outra. Depois:

1. espera `board-alert-limit-<id>`;
2. `runner.stop()` e espera `board-alert-offline-<id>` sem reload;
3. na página da tarefa, espera `task-runner-offline`;
4. `shot`s `board-alertas` e `task-runner-offline`.

Page Objects, só com `getByTestId`:
- `AppPage.openBoard(slug)` e `AppPage.boardAlert(kind, taskId)`;
- `TasksPage.show(slug, taskId)` e `TasksPage.runnerOffline`.

## Comandos e saídas

`mix format` rodou sem mudanças pendentes.

```
mix test apps/pipe_maestro/test/pipe_maestro/tasks_test.exs \
  apps/pipe_maestro_web/test/pipe_maestro_web/live/board_live_test.exs \
  apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs
```

**Domínio:** `Result: 55/57 passed, Failed: 2 tests`.

```
1) test the task's budget runner_offline?: a running task whose runner is not online (PipeMaestro.TasksTest)
   ** (UndefinedFunctionError) function PipeMaestro.Tasks.runner_offline?/2 is undefined or private
   code: assert Tasks.runner_offline?(task, MapSet.new())

2) test the task's budget alerts_change_at: the earliest future reset of a runner near its limit (PipeMaestro.TasksTest)
   ** (UndefinedFunctionError) function PipeMaestro.Tasks.alerts_change_at/2 is undefined or private. Did you mean:
       * alerts/2
   code: assert Tasks.alerts_change_at([], now) == nil
```

Falha esperada: as duas funções públicas do plano ainda não existem. O setup (tarefa
criada, `run_current` até `:awaiting_decision`) roda inteiro antes da chamada.

**Web:** `Result: 33/36 passed, Failed: 3 tests`.

```
1) test with tasks the limit alert shows as soon as a rate_limit is recorded, live (PipeMaestroWeb.BoardLiveTest)
   Expected truthy, got false
   code: assert eventually(fn -> has_element?(view, "[data-testid=board-alert-limit-#{task.id}]", "mac") end)
```
Falha esperada: hoje `:runners_changed` só chama `load_runners/1`, então o `rate_limit`
gravado não chega aos alertas enquanto o Board está aberto.

```
2) test with tasks the limit alert goes away by itself when the limit resets (PipeMaestroWeb.BoardLiveTest)
   Expected truthy, got false
   code: assert eventually(fn -> not has_element?(view, "[data-testid=board-alert-limit-#{task.id}]") end, 250)
```
Falha esperada: o alerta aparece no mount (a primeira asserção passa), mas não há timer
até `resets_at` e ele não some.

```
3) test show a running task warns while its runner is offline, live (PipeMaestroWeb.TaskLiveTest)
   Expected truthy, got false
   code: assert eventually(fn -> has_element?(view, "[data-testid=task-runner-offline]", "mac") end)
```
Falha esperada: `TaskLive.Show` não assina `RunnerStatus` nem renderiza o aviso. O
`refute` inicial, com o runner online, passa.

**Testes que já existiam:** todos passam nos três arquivos. As únicas falhas são os
5 testes novos acima.

### e2e

```
make e2e.typecheck   → exit 0 (cd e2e && npx tsc --noEmit)
make e2e FILE=tests/board-alerts.spec.ts   → exit 2
```

```
✘ [chromium] › tests/board-alerts.spec.ts:24:7 › Board alerts › the board's alerts follow the runner, live
  Error: expect(locator).toContainText(expected) failed
  Locator: getByTestId('board-alert-limit-8906435b-…')
  Expected substring: "alerta-mw2hfwxnqw"
  Error: element(s) not found
  > 70 | await expect(board.boardAlert("limit", taskId)).toContainText(runnerName);
```

Falha esperada: o runner real reportou o `rate_limit` do `fake_claude` (86%), mas o
Board aberto não recalcula os alertas em `:runners_changed`. Todo o setup passou antes
disso: login, device flow, runner online, pipelines prontos e tarefa criada, com
status "Executando".

## Commit

`test: alertas do Board e da tarefa acompanham o runner ao vivo`, só com os arquivos de
teste e Page Objects:
- `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs`
- `apps/pipe_maestro_web/test/pipe_maestro_web/live/board_live_test.exs`
- `apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs`
- `e2e/tests/board-alerts.spec.ts`
- `e2e/pages/AppPage.ts`
- `e2e/pages/TasksPage.ts`

## Notas para a implementação

- O plano sugere `data-testid="board-alerts"` no card "Precisa de atenção". O spec não
  depende dele.
- Depois da implementação, o e2e só passa se `[limite]` disparar o alerta antes dos
  30 s de `[lento]`. O evento vem logo após o `init` do `fake_claude`, então há folga.
