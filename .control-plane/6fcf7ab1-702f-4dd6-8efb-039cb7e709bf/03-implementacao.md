# Implementação — runner resiliente a reinícios e à atualização

Etapa 3. Segue o plano (`01-plano.md`, D1 a D5) e faz passar os testes de `02-testes.md`.
Os testes da etapa 2 não foram enfraquecidos. Os que mudaram estão listados abaixo, com o
motivo.

## Duas execuções nesta worktree

Durante esta etapa, a plataforma tratou a execução como perdida: o runner que executa o
pipeline foi atualizado por um deploy, que é justamente o caso desta tarefa. Ela subiu
outra execução da mesma etapa na mesma worktree, e as duas commitaram em paralelo na
branch, sem conflito. A segunda escreveu a documentação (`e4a796b`: ADR 0041, specs e
guia de deploy) e uma primeira versão deste artefato (`53094c7`). Esta versão a
substitui. Ela foi conferida contra o código e corrige dois pontos: a lista de testes
alterados e o `Hello`, que agora usa `finished_job_ids`. Também acrescenta a reprodução
com processos reais.

## O que mudou, por app

### `apps/pipe_maestro_protocol`

- `runner_log.ex`: `update_draining` na lista fechada de eventos do `runner:log`. A
  mudança é aditiva e `protocol_version` não sobe.
- **Runner antigo:** é compatível. Ao ser recusado, ele cancela os jobs e sai pelo código
  antigo. O `job:finished` `canceled` sem pedido que ele entrega conta como perda, e os
  jobs que ele não reporta voltam pela reconciliação sem gastar tentativa. Os dois casos
  têm teste: `job_lost_test.exs` ("an end reported as canceled with no one asking counts
  as lost" e "is not an attempt…").

### `apps/pipe_maestro` (domínio)

- `tasks/stage_run.ex` e a migração `20261116100000_add_requeue_to_stage_runs.exs`:
  status `:lost` e campo `requeue` (inteiro, padrão 0).
- `tasks.ex`:
  - `job_lost/1`, idempotente. O `StageRun` vira `:lost` com o motivo, e a etapa roda de
    novo na mesma tentativa (`requeue + 1`), com as mesmas instruções, respostas e
    feedback, no mesmo runner e worktree, sem gate e sem análise;
  - depois de `max_lost_requeues` perdas (3, configurável), a tarefa vai para
    `awaiting_decision` sem análise. Num grupo, a etapa perdida no limite entra no
    `close_step` como problema, também sem análise;
  - cada perda grava o evento `job_lost` (warning, grupo `connection`), com `job_id` e
    `task_id`;
  - `start_stage` foi dividido em `run_stage` + `requeue_stage`. As consultas da última
    tentativa (`attempts_query`, `latest_run`, `previous_feedback`) desempatam por
    `requeue`, e `previous_feedback` ignora `:lost`;
  - `close_step` foi quebrado em `problem/1` e `step_asking/1` (Credo).
- `jobs.ex`:
  - `reconcile/2` falha o job perdido com "Perdido: o runner reiniciou durante a
    execução." e, se for de etapa, o manda para `Tasks.job_lost/1`;
  - `finish_job/3` trata um `canceled` sem `cancel_requested_at` como perda;
  - `running_among/2` é nova e serve ao canal.
- `runner_telemetry/event.ex`: `job_lost` (connection) e `update_draining` (update).
- `integrations/feedback.ex`: a última tentativa de cada etapa desempata por `requeue`.

### `apps/pipe_maestro_web`

- `channels/runner_channel.ex`: a cada join, para cada job `running` que o runner diz
  seguir rodando, o canal reenvia `job:cancel` se o cancelamento foi pedido com o canal
  fora. Senão, manda já um `job:credential` novo e agenda a próxima renovação.
- `live/task_live/show.ex`:
  - os test ids e DOM ids das tentativas passam por `run_ref/1`, com o sufixo
    `-r<requeue>` quando `requeue > 0`;
  - a tentativa perdida mostra o motivo em `stage-run-lost-<key>-<attempt>`;
  - "Tentativa 1 · de novo (1)" no cabeçalho;
  - a contagem de tentativas por etapa conta números distintos (`stage-attempts-<key>`).
- `components/task_components.ex`: badge "Perdida (runner)", `warning`, via
  `<.badge>` da Petal.
- `pipeline_diagram.ex`: o estado `:lost` aparece como `:blocked`, e a ordenação
  desempata por `requeue`.
- `live/runner_live/log_tab.ex`: rótulos "job perdido" e "terminando jobs".

### `apps/pipe_maestro_runner`

- `outbox.ex`: `persist_all/1` grava tudo o que falta confirmar.
  `finished_job_ids/1`: só um job com `job:finished` pendente conta como rodando no
  `Hello`. Um job parado como perdido na drenagem tem só `job:started` e eventos na
  outbox. Se ele entrasse em `running_job_ids`, o control plane o deixaria `running` para
  sempre.
- `outbox/server.ex` (novo): dono da outbox. É o `owner` do `JobRunner`, encaminha à
  conexão registrada (`{:outbox_out, id, …}`) e recebe dela `sent`/`confirmed`.
- `connection/keeper.ex` (novo): sobe a `Connection` e, se ela cai, sobe outra com backoff
  de 500 ms a 30 s, sem limite. O backoff volta ao início depois de uma conexão que durou
  1 min. Uma conexão que para com `:normal` (recusa ou drenagem) não volta.
- `session.ex` (novo): supervisor com `Outbox.Server`, `JobRunner` e `Keeper`.
  `connection/1` e `job_runner/1`.
- `connection.ex`:
  - recebe `:outbox` e `:job_runner` por opção, ou cria os seus, como antes;
  - recusado com `"outdated"`, drena em vez de cancelar. Para de iniciar jobs, espera os
    que rodam até `:drain_timeout_ms` (padrão 30 min) e, se o prazo vence, os para como
    `:lost`. Registra `update_draining`, faz `persist_all` e só então avisa
    `{:outdated, _}` e para;
  - drenando, não reconecta;
  - `job_runner_opts/3` é público e serve à `Session`.
- `job_runner.ex`: `drain/1` descarta a fila e não aceita nada novo. `cancel/3` com
  `:lost` para o processo sem mandar `job:finished`. O `owner` aceita um nome.
- `self_update.ex`:
  - `mode/2` decide pelo ambiente (`PIPEMAESTRO_SERVICE`, `PIPEMAESTRO_RELAUNCH_PARENT`,
    `XPC_SERVICE_NAME`, `INVOCATION_ID` sem TTY) e não só pelo TTY;
  - `relaunch/4`: `:service` dá halt 0 e `:handoff` dá halt 75;
  - `:interactive`: o pai fica fixo e relança enquanto o filho devolve 75;
  - `:detached`: `spawn_detached/2` sobe o binário em background com `trap "" HUP` e a
    mesma saída, e depois sai com 0. Usa `trap` e não `nohup`, que desviaria a saída para
    `nohup.out` quando ela é um terminal. Isso apareceu na reprodução abaixo.
- `update.ex`: `consent/2` dá só o consentimento, e o modo vem de `SelfUpdate.mode/2`. Se
  o binário novo não sobe no `:detached`, devolve `{:fail, msg}`.
- `service.ex`: `PIPEMAESTRO_SERVICE=1` no plist (`EnvironmentVariables`) e no unit.
- `instance_lock.ex` (novo):
  - `runner.pid` no diretório de configuração;
  - `acquire/2` espera até 30 s um runner anterior vivo sair (`kill -0`);
  - `release/2` só apaga o lock do próprio runner.
- `commands/start.ex`:
  - toma o lock e sobe a `Session` (monitorada, sem link);
  - aceita `--drain-timeout` em minutos, ou `PIPEMAESTRO_DRAIN_TIMEOUT_MS` nos testes;
  - recusado por versão, solta o lock antes de `Update.handle/2`;
  - o `{:DOWN, …}` vem só da `Session`.

### e2e

- `e2e/tests/runner-restart.spec.ts`: o flow passou para `[done]`.

### Documentação

A outra execução escreveu (`e4a796b`), e esta conferiu e ajustou:

- `docs/adr/0041-runner-resiliente-a-reinicios.md`: D1 a D5. Ajustes: o `Hello` só conta
  um `job:finished` pendente, e o `:detached` não usa `nohup`;
- `docs/specs/protocolo-runner.md`: §3, §4.1, §4.2 (com o ajuste de `running_job_ids`),
  §4.6 e §4.7;
- `docs/specs/maquina-de-estados-tarefa.md`: a perda como tabela;
- `docs/guias/deploy.md`: a nota de transição para runners antigos fora do serviço.

## Testes da etapa 2 que mudaram, e por quê

| Teste | Mudança | Por quê |
|---|---|---|
| `job_lost_test.exs` | `Map.get(run, :requeue)` virou `run.requeue` | A própria nota da etapa 2 pedia isso quando o campo existisse |
| `self_update_test.exs` ("detached: starts the new binary on its own") | `send(...) && :ok` virou duas linhas | O compilador avisava que a condição é sempre verdadeira, e `--warnings-as-errors` falhava. O teste continua igual |
| `task_live_test.exs` (tentativa perdida) | ganhou `refute stage-attempts-a` | Reforço: uma tentativa rodada de novo não conta como duas |

## Testes que já existiam e mudaram com o comportamento novo

| Teste | Antes | Agora | Por quê |
|---|---|---|---|
| `tasks_test.exs` "a canceled job cancels the task" | `canceled` sem pedido cancelava a tarefa | "a job canceled on request cancels the task" pede o cancelamento (`request_cancel`) antes | D3: um `canceled` sem pedido é perda. O caso sem pedido está em `job_lost_test.exs` |
| `jobs_test.exs` reconcile | erro `"O runner…"` | erro `"Perdido: o runner…"` | O texto novo é o que `job_lost_test` fixa |
| `update_test.exs` (2 testes "for the service manager") | sem TTY dava `:service` | o ambiente leva `PIPEMAESTRO_SERVICE=1` | D1: a ausência de TTY sozinha não indica um serviço |
| `update_test.exs` (novo) | — | sem TTY e fora do serviço dá `:detached` | O caso `nohup`/pipe do plano |

## Testes novos desta etapa

- `instance_lock_test.exs`: livre, holder morto, espera o anterior sair, holder que fica
  (erro), o próprio pid vivo checado com `kill -0`, e `release/2` só do próprio.
- `outbox_test.exs`: `finished_job_ids/1`.

## Reprodução do relançamento com processos reais

Feita nesta máquina com `mix run --no-start` chamando `SelfUpdate.mode/2` e `relaunch/4`.
O "binário novo" foi um script, e o TTY foi lido direto do OTP, porque `Output.tty?/0` dá
`false` sob Mix de propósito:

| Cenário | Modo | Resultado |
|---|---|---|
| (a) num pty (`pty.spawn`), filho devolvendo 75, 75 e 0 | `:interactive` | O pai fixo relançou 3 vezes, sempre com o mesmo `ppid`: dois níveis, sem cadeia crescente. Recebeu `PIPEMAESTRO_RELAUNCH_PARENT=1` e devolveu 0. A saída do filho chegou ao terminal (stdin e stderr são tty) |
| (b) `nohup mix run … > log 2>&1 &` | `:detached` | O binário novo rodou adotado pelo init (`ppid=1`) com os mesmos argumentos, e o antigo saiu com 0. Na 1ª versão, com `nohup`, a saída de um pty foi para `nohup.out`, e daí veio a troca por `trap "" HUP` |
| (c) `PIPEMAESTRO_SERVICE=1` sem TTY | `:service` | halt 0 |

**Pendente:** a reprodução ponta a ponta com o binário Burrito
(`make runner.binary TARGET=macos_arm64`, um servidor local exigindo outra versão do
runner e `pipemaestro service install`). Ela não foi feita: `service install` mexe no
launchd da máquina que executa este pipeline, e trocar o binário do runner real derruba
a própria execução. Fica para a revisão humana, numa máquina que não seja a do runner
do pipeline:

```sh
make runner.binary TARGET=macos_arm64
# servidor local exigindo outra versão do runner; rodar o binário:
#  (a) no terminal; (b) nohup ./pipemaestro start >log 2>&1 &; (c) pipemaestro service install
# em cada um: baixa, troca e volta online sozinho; no caso (a), `ps` mostra no máximo 2 BEAMs.
```

## Como verificar

```sh
make ci > /tmp/ci.log 2>&1; echo $?          # 0 (inclui o Dialyzer)
make ci.quick > /tmp/ciq.log 2>&1; echo $?   # 0
# e2e com as portas dos fakes livres (outra worktree pode estar usando 4013/4014):
E2E_FORGEJO_PORT=4613 E2E_GITHUB_PORT=4614 make e2e.shots FILE=tests/runner-restart.spec.ts
```

## Resultados

- `make ci`: saiu 0. Credo sem problemas; protocol 105, domínio 517, web 462 e runner 248
  testes passando; cobertura dentro do limite; Dialyzer com 0 erros.
- `make e2e.shots FILE=tests/runner-restart.spec.ts`: passou. As telas foram conferidas
  em claro e escuro: a linha do tempo com "Perdida (runner)", o motivo e "Tentativa 1 · de
  novo (1)", e a aba de eventos do runner com "job perdido" no filtro Conexão. A
  contagem errada "2 tentativas" apareceu nos screenshots e foi corrigida (`bb583d3`).
- A suíte e2e inteira não rodou nesta execução. A outra execução a iniciou, e o
  resultado final fica para a etapa de Telas (e2e).
