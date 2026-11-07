# Testes que falham — runner resiliente a reinícios e atualização

Etapa 2. Os testes descrevem o comportamento do plano (`01-plano.md`, §3 e §8) e
ainda não há implementação. Nenhum stub foi criado: cada teste falha por
`UndefinedFunctionError`, por módulo inexistente ou por asserção sobre o
comportamento atual.

## Arquivos

| App | Arquivo | O que cobre (decisão do plano) |
|---|---|---|
| protocol | `apps/pipe_maestro_protocol/test/pipe_maestro_protocol/runner_log_test.exs` | `update_draining` na lista de eventos do `runner:log` (§6) |
| runner | `apps/pipe_maestro_runner/test/pipe_maestro_runner/self_update_test.exs` | `SelfUpdate.mode/2` em cada linha da tabela de D1, incluindo os serviços antigos (`XPC_SERVICE_NAME`, `INVOCATION_ID` sem TTY); `relaunch/4` em `:handoff` (halt 75), `:detached` (spawn injetável e depois halt 0; e um spawn real que roda o binário novo sem a release antiga) e `:interactive` (o pai fixo relança enquanto o filho devolve 75, e o filho recebe `PIPEMAESTRO_RELAUNCH_PARENT=1`) |
| runner | `apps/pipe_maestro_runner/test/pipe_maestro_runner/service_test.exs` | `PIPEMAESTRO_SERVICE=1` no plist e no unit; o ambiente do serviço dá `:service` |
| runner | `apps/pipe_maestro_runner/test/pipe_maestro_runner/outbox_test.exs` | `Outbox.persist_all/1` grava tudo (`job:started`, `job:event`, `job:telemetry`, `job:finished`) e em ordem; sem arquivo, não faz nada (D2.3) |
| runner | `apps/pipe_maestro_runner/test/pipe_maestro_runner/job_runner_test.exs` | `JobRunner.drain/1` (o job rodando segue, a espera é descartada e nada novo começa) e `cancel/3` com `:lost` (para sem mandar `job:finished`) (D2.1, D2.4) |
| runner | `apps/pipe_maestro_runner/test/pipe_maestro_runner/connection_drain_test.exs` (novo) | Recusado por `"outdated"` com um job rodando: o job termina e o `{:outdated, _}` só chega depois, com `job:finished` e `job:started` no `outbox.bin`. Com o prazo vencido (`drain_timeout_ms: 300`), o job é parado e **não** fica `job:finished` na outbox (D2) |
| runner | `apps/pipe_maestro_runner/test/pipe_maestro_runner/session_test.exs` (novo) | `Session` (Supervisor): `Process.exit(conexão, :kill)` com um job rodando. A `Session` e o `JobRunner` seguem vivos, o job continua, uma conexão nova faz join com `running_job_ids: ["j1"]` e a outbox reenviada (D4) |
| domínio | `apps/pipe_maestro/test/pipe_maestro/tasks/job_lost_test.exs` (novo) | Perda sem gastar tentativa: `StageRun` `:lost` e um novo com o mesmo `attempt` e `requeue: 1`, job novo no mesmo runner e worktree, mesmo prompt, `instructions` e `feedback`; o job perdido fica `failed` com "Perdido: o runner reiniciou…"; sem gate e sem análise; evento `job_lost` (grupo `connection`) com `job_id` e `task_id`; limite de 3 reenfileiramentos e, na quarta perda, `awaiting_decision` com "interrompida 4 vezes" e sem análise; perda depois de uma tentativa falha refaz a mesma tentativa com o feedback dela; `Tasks.job_lost/1` idempotente; `canceled` sem pedido conta como perda e com pedido continua cancelando; etapa de grupo perdida roda de novo sozinha e o grupo segue (D3) |
| domínio | `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs` | O teste "a job lost … counts as a failed attempt" descrevia o comportamento antigo. Agora espera `[:lost attempt 1, :running attempt 1]` |
| web | `apps/pipe_maestro_web/test/pipe_maestro_web/channels/runner_channel_test.exs` | Restart do servidor: o canal novo manda `job:credential` na hora para o job que segue rodando; `job:cancel` pedido com o canal fora é reenviado no join; job de etapa perdido gera job novo e evento `job_lost` (D3, D5) |
| web | `apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs` | Linha do tempo: badge "Perdida (runner)" em `stage-run-status-a-1`, motivo em `stage-run-lost-a-1`, a tentativa de novo em `stage-run-a-1-r1` / `stage-run-status-a-1-r1` e nenhuma `stage-run-a-2` (§7) |
| e2e | `e2e/tests/runner-restart.spec.ts` (novo) e `e2e/pages/TasksPage.ts` | O runner real é parado no meio de uma etapa `[lento]` e sobe de novo. A etapa aparece "Perdida (runner)" com o motivo, roda de novo como `-r1`, sem tentativa 2, e o evento `job_lost` aparece na aba de eventos do runner (filtro `connection`). Page Object ganhou `requeuedRunStatus/3` e `stageRunLost/2` |

## Como os testes falham

`mix format` rodou sem mudanças pendentes. `mix test` na raiz: **todas as falhas
são dos testes novos ou alterados**; os testes que já existiam continuam
passando.

```
==> pipe_maestro_protocol   Result: 104/105 passed   Failed: 1 test
==> pipe_maestro            Result: 507/517 passed   Failed: 10 tests
==> pipe_maestro_web        Result: 458/462 passed   Failed: 4 tests
==> pipe_maestro_runner     Result: 220/240 passed   Failed: 20 tests
```

### protocol

```
1) test a runner draining its jobs before updating is an event (PipeMaestroProtocol.RunnerLogTest)
   Assertion with in failed
   code:  assert "update_draining" in RunnerLog.events()
   right: ["update_applied", "update_failed", "scratch_remove_failed",
           "outbox_dropped", "connection_lost", "log_dropped"]
```

O evento ainda não está na lista fechada `@events`.

### runner

```
** (UndefinedFunctionError) function PipeMaestroRunner.SelfUpdate.mode/2 is undefined or private
```
Os 8 testes de `mode/2` e o do `service_test`: a função não existe.

```
** (FunctionClauseError) no function clause matching in PipeMaestroRunner.SelfUpdate.relaunch/4
    # 3
    :handoff        (e o mesmo com :detached, nos dois testes do modo)
```
Hoje `relaunch/4` só conhece `:interactive` e `:service`.

```
interactive: the parent stays, running the new binary again while it hands back 75
   Assertion with == failed
   code:  assert SelfUpdate.relaunch(bin, ["start"], :interactive) == 4
   left:  75
   right: 4
```
Hoje o pai devolve o status do primeiro filho, sem o laço do status 75.

```
the service marks its environment ...
   Assertion with =~ failed
   code:  assert plist =~ "<key>PIPEMAESTRO_SERVICE</key>\n    <string>1</string>"
```
O plist e o unit ainda não marcam o ambiente.

```
** (UndefinedFunctionError) function PipeMaestroRunner.Outbox.persist_all/1 is undefined or private
** (UndefinedFunctionError) function PipeMaestroRunner.JobRunner.drain/1 is undefined or private
** (UndefinedFunctionError) function PipeMaestroRunner.JobRunner.cancel/3 is undefined or private. Did you mean: cancel/2
```
São as funções novas de D2.

```
refused for its version, it lets the running job finish and keeps its end before updating
   Unexpectedly received message {:runner_connection, {:outdated, %{"reason" => "outdated", ...}}}
   code: refute_receive {:runner_connection, {:outdated, _refusal}}, 1_000
```
Hoje `handle_topic_close/3` cancela o job (`stop_jobs/1`) e avisa `:outdated` na hora,
sem esperar o job terminar.

```
past the deadline, the job is stopped as lost: no end of it is kept
   Assertion with in failed
   code:  assert {"job:started", "j1", nil} in kept(outbox)
   right: []
```
Hoje a outbox só grava os duráveis e não persiste tudo antes de atualizar.

```
a crashed connection is started again ... (PipeMaestroRunner.SessionTest)
   ** (ArgumentError) The module PipeMaestroRunner.Session was given as a child to a supervisor but it does not exist
```
O módulo `Session` de D4 não existe. A falha acontece no `setup`, porque é ali que a
`Session` sobe. Equivale a um `UndefinedFunctionError`, não a um erro de configuração
do teste.

### domínio

```
is not an attempt: the stage runs again in the same attempt, on the same worktree
   code:  assert timeline(task) == [{1, 0, :lost}, {1, 1, :running}]
   left:  [{1, nil, :failed}, {2, nil, :running}]
```
Hoje a perda vira a tentativa `failed` e a tentativa 2 começa. Não há `:lost` nem `requeue`.

```
the run again keeps the instructions and feedback of the lost one, and its reason
   code:  assert again.feedback == lost.feedback
   left:  "Erro: O runner reiniciou durante a execução."
   right: nil
```
Hoje a perda passa pelo gate e vira feedback de erro para o agente.

```
is told as an event of the runner
   code:  assert [%{kind: "job_lost", ...}] = RunnerTelemetry.events(ctx.runner, since, "connection")
   right: []
```
O evento `job_lost` não existe.

```
past the limit of losses in one attempt ...
   Assertion failed: stage a is not running
```
Hoje, na segunda perda, a tarefa já esgotou as tentativas e para.

```
is idempotent: ...
   ** (UndefinedFunctionError) function PipeMaestro.Tasks.job_lost/1 is undefined or private
```

```
an end reported as canceled with no one asking counts as lost
   code:  assert %Task{status: :running} = task      (a tarefa ficou :canceled)
```

```
a loss after a failed attempt runs that attempt again, with its feedback
   left:  [{1, nil, :failed}, {2, nil, :failed}]
a stage of a group runs again alone ...
   left:  [{1, nil, :failed}, {2, nil, :running}]
the gate does not run: the task asks for no analysis
   code: refute Enum.any?(task.stage_runs, &(&1.status == :failed))
the gate a job lost by a restarted runner runs the stage again, in the same attempt (TasksTest)
   code: assert [%StageRun{status: :lost, attempt: 1}, %StageRun{status: :running, attempt: 1}] = task.stage_runs
```
Todos falham pelo mesmo motivo: a perda ainda conta como tentativa falha.

O teste "a cancel someone asked for still cancels the task" **passa**, como deve. Ele
protege o cancelamento pedido por uma pessoa contra a regra nova do `canceled` sem
pedido.

### web

```
after a restart of the server, a job still running gets its credential again at once
   Assertion failed, no matching message after 100ms
   code: assert_receive %{... event: "job:credential", payload: %{"job_id" => ^job_id, ...}}
a cancel asked while the runner was away reaches it when it rejoins
   Assertion failed, no matching message after 100ms
   code: assert_receive %{... event: "job:cancel", payload: %{"job_id" => ^job_id}}
```
O `after_join` ainda não renova a credencial nem reenvia o cancelamento pendente.

```
a stage job lost in a restart of the runner runs again, to the same runner
   code:  assert [%{kind: "job_lost", job_id: ^lost_id}] = RunnerTelemetry.events(...)
   right: []
```
Antes desse ponto, o job novo já é entregue ao runner, mas hoje como tentativa 2.
O evento falta.

```
shows the lost run apart from a failure, and the run again under the same attempt
   Expected truthy, got false
   code: assert has_element?(view, "[data-testid=stage-run-status-a-1]", "Perdida (runner)")
```

### e2e

`make e2e.typecheck`: passa (exit 0).
`make e2e FILE=tests/runner-restart.spec.ts`: falha pelo motivo certo.

```
Error: expect(locator).toHaveText(expected) failed
Locator: getByTestId('stage-run-status-executar-1')
- Perdida (runner)
+   Falhou
```

O runner real (`mix runner.start`) foi parado e subiu de novo. A plataforma tratou o job
perdido como tentativa falha.

## Notas para a implementação

- Os testes leem `requeue` com `Map.get(run, :requeue)` porque o campo ainda não existe
  no `StageRun`, e `%StageRun{requeue: _}` não compilaria. O compilador avisa
  "incompatible types given to Map.get/2". O aviso some quando o campo existir, e
  aí vale trocar por `run.requeue` em `job_lost_test.exs`. Os avisos de função
  indefinida (`SelfUpdate.mode/2`, `Tasks.job_lost/1`) também somem com a
  implementação. Até lá, `mix test --warnings-as-errors` não passa, como esperado
  nesta etapa.
- APIs que os testes fixam:
  - `SelfUpdate.mode(env, tty?) :: :service | :handoff | :interactive | :detached`;
  - `SelfUpdate.relaunch/4` com as opções `:spawn` (`fn bin, argv -> ... end`) e `:halt`.
    O `:detached` padrão roda o binário com os mesmos argumentos e sem as variáveis da
    release antiga (`child_env/1`);
  - `Outbox.persist_all/1 :: :ok`;
  - `JobRunner.drain/1 :: :ok` e `JobRunner.cancel/3` com `:lost`;
  - opção `:drain_timeout_ms` da `Connection`;
  - `Session.start_link/1` (as opções da `Connection`), `Session.connection/1` (pid da
    conexão da vez) e `Session.job_runner/1`;
  - `Tasks.job_lost/1 :: :ok`, idempotente;
  - o erro do job perdido começa com "Perdido: o runner reiniciou", e o motivo da pausa
    contém o nome da etapa e "interrompida N vezes";
  - test ids `stage-run-<key>-<attempt>-r<requeue>`, `stage-run-status-…-r<requeue>` e
    `stage-run-lost-<key>-<attempt>`.
- O plano não define a API do lock de instância (`runner.pid`) nem a de `--drain-timeout`
  em `Commands.Start`, e esta etapa não tem teste para eles. A etapa de implementação
  cobre os dois junto com o código e com a reprodução manual no binário Burrito
  (cenários a, b e c do plano).
- O flow do spec novo está como `[todo]`. Ele vira `[done]` quando passar.
