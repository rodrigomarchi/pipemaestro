# Implementação — runner resiliente a reinícios e à atualização

Etapa 3. Segue o plano (`01-plano.md`, D1 a D5) e faz passar os testes de `02-testes.md`
sem enfraquecê-los.

## Sobre a tentativa anterior

A tentativa anterior terminou com "O runner reiniciou durante a execução". O runner que
executa este pipeline (binário Burrito em `~/Library/Application Support/.burrito/…+dev-147ed64.20261107124747`)
foi trocado às 12:47 por uma atualização de versão vinda de um deploy: um evento
externo, e justamente o caso que esta tarefa corrige. Os commits dos blocos 1 a 5 já
estavam na branch e foram mantidos. Esta tentativa:

- commitou o refactor que ficou pendente em `tasks.ex` (Credo);
- escreveu a documentação (bloco 7);
- rodou `make ci.quick` e o e2e.

Para não arriscar o runner real, **não rodei a reprodução manual com o binário Burrito
nem `service install`** (§1 do plano). Eles mexem no launchd da máquina que executa o
pipeline. Os três cenários (terminal, `nohup … &`, serviço) estão cobertos por
`self_update_test.exs` (`mode/2` e os relaunches com `halt`/`Port` injetados) e
`service_test.exs`. A reprodução com o binário fica para a revisão humana, numa máquina
que não seja a do runner do pipeline:

```sh
make runner.binary TARGET=macos_arm64
# servidor local exigindo outra versão de runner; rodar o binário:
#  (a) no terminal; (b) nohup ./pipemaestro start >log 2>&1 &; (c) pipemaestro service install
# em cada um: o runner baixa, troca e volta online sozinho, e `ps` mostra no máximo 2 BEAMs no caso (a).
```

## O que mudou, por app

### `apps/pipe_maestro` (domínio)

- `tasks/stage_run.ex` e a migração `20261116100000_add_requeue_to_stage_runs.exs`:
  status `:lost` e campo `requeue`.
- `tasks.ex`: `job_lost/1` (perda por infraestrutura reenfileira a etapa na mesma
  tentativa, até `max_lost_requeues` = 3; depois `awaiting_decision` sem análise). As
  consultas da última tentativa desempatam por `requeue` e ignoram `:lost`.
- `jobs.ex`: `reconcile/2` manda os jobs de etapa perdidos para `Tasks.job_lost/1`, e um
  `canceled` sem pedido conta como perda.
- `runner_telemetry/event.ex`: `job_lost` no grupo `connection`.
- `integrations/feedback.ex`: a última tentativa de cada etapa desempata por `requeue`.

### `apps/pipe_maestro_web`

- `channels/runner_channel.ex`: depois do join, credencial git nova e renovação agendada
  para os jobs que seguem rodando, e `job:cancel` reenviado aos que têm cancelamento
  pedido.
- `task_live/show.ex`, `components/task_components.ex`, `pipeline_diagram.ex`: badge
  "Perdida (runner)", motivo da perda (`stage-run-lost-<key>-<attempt>`) e o sufixo
  `-r<n>` nos test ids das tentativas reenfileiradas.
- `runner_live/log_tab.ex`: rótulos de `job_lost` ("job perdido") e `update_draining` ("terminando jobs").

### `apps/pipe_maestro_protocol`

- `runner_log.ex`: `update_draining` na lista fechada de eventos. Mudança aditiva:
  `protocol_version` não sobe. Runner antigo: compatível (ver a ADR, "Consequências"),
  e o caso de um runner antigo que cancela por conta própria ao ser recusado é testado em
  `job_lost_test.exs` ("an end reported as canceled with no one asking counts as lost").

### `apps/pipe_maestro_runner`

- `self_update.ex`: `mode/2` (`:service`, `:handoff`, `:interactive`, `:detached`) e os
  relaunches; `update.ex` usa o modo; `service.ex` grava `PIPEMAESTRO_SERVICE=1`.
- `instance_lock.ex` (novo): `runner.pid`, um runner por configuração.
- `session.ex`, `connection/keeper.ex`, `outbox/server.ex` (novos): conexão
  supervisionada, reiniciada com backoff sem perder jobs nem outbox.
- `connection.ex`: drenagem assíncrona ao ser recusado por versão (`--drain-timeout`),
  `persist_all` da outbox antes de atualizar.
- `job_runner.ex`: `drain/1` e `cancel/3` com `:lost`; `outbox.ex`: `persist_all/1`.
- `commands/start.ex`: lock, `--drain-timeout`, supervisão pela `Session`.

### e2e

- `e2e/tests/runner-restart.spec.ts` e `e2e/pages/TasksPage.ts`: o runner cai com uma
  etapa em andamento, volta, e a etapa aparece "Perdida (runner)" e roda de novo na mesma
  tentativa; o evento `job_lost` aparece nos eventos do runner.

### Documentação

- `docs/adr/0041-runner-resiliente-a-reinicios.md` (nova): D1 a D5.
- `docs/specs/protocolo-runner.md`: §3 (drenagem), §4.1 (credencial e cancelamento no
  join), §4.2 (outbox em arquivo, não mais "vive em memória"), §4.6 (perda por
  infraestrutura), §4.7 (`update_draining`).
- `docs/specs/maquina-de-estados-tarefa.md`: a perda vira uma tabela própria.
- `docs/guias/deploy.md`: comportamento no deploy e nota de transição para runners
  antigos fora do serviço.

Nenhum teste da etapa 2 foi alterado nesta tentativa.

## Como verificar

```sh
make ci.quick > /tmp/ciq.log 2>&1; echo $?     # 0
# e2e, com as portas dos fakes livres (outra worktree pode estar usando 4013/4014):
E2E_FORGEJO_PORT=4931 E2E_GITHUB_PORT=4932 make e2e FILE=tests/runner-restart.spec.ts
E2E_FORGEJO_PORT=4931 E2E_GITHUB_PORT=4932 make e2e.shots
```

## Resultados

- `make ci.quick`: saiu 0.
- `make e2e FILE=tests/runner-restart.spec.ts`: 1 passou.
- `make e2e.shots` (suíte inteira, claro e escuro): estava rodando ao fechar esta etapa,
  sem falhas até ali. O resultado final fica para a etapa de Telas (e2e).
