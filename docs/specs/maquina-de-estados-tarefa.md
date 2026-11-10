# Máquina de estados da tarefa

> Implementada em `PipeMaestro.Tasks` (transições) e
> `PipeMaestro.Tasks.Engine` (gate). Decisão de desenho: [ADR 0005](../adr/0005-pipelines-e-tarefas.md).

## Tarefa

```
                      ┌──────────── retry_stage / advance ───────────┐
                      ▼                                              │
create_task ──► running ──(gate: bloqueada, esgotada, regra)──► awaiting_decision
                  │  ▲                                               │
                  │  └──(gate: nova tentativa / próxima etapa)       │
                  │                                                  │
                  ├──(gate: última etapa aprovada)──► succeeded      │
                  ├──(job cancelado)────────────────► canceled ◄─────┘ cancel_task
                  ├──(cancel_task: cancela o job; o runner confirma)
                  └──(interrupt: job cancelado com pausa)──► awaiting_decision

succeeded / canceled ──(correct: nova etapa "Correção N")──► running
qualquer estado menos running ──(redo_from)──► running
```

A tarefa nasce de um projeto ([ADR 0034](../adr/0034-o-projeto-e-a-escolha-de-onde-o-trabalho-roda.md)):
`create_task` recebe `project_id`, e o runner, a pasta, `git` e o retrato saem dele. Um
projeto sem runner, ou cujo runner não oferece mais a pasta, recusa a tarefa. Com o runner
offline a tarefa é criada em `running` e o job da primeira etapa fica `queued` até o runner
conectar (`Tasks.waiting_for_runner?/2`); a tela diz que ela espera o runner, em vez do
alerta de tarefa parada (`runner_offline?/2`), que vale quando um job já começou.

Nenhum estado é uma rua sem saída ([ADR 0032](../adr/0032-sem-ruas-sem-saida.md)): uma
tarefa parada ou encerrada sempre aceita um novo prompt.

| Estado | Significado |
|---|---|
| `running` | Uma tentativa da etapa `current_stage` está na fila ou rodando no runner. |
| `awaiting_decision` | Uma pessoa precisa decidir; o motivo está em `decision_reason`, e as perguntas, quando há, em `decision_questionnaire` ([ADR 0029](../adr/0029-questionario-de-decisao.md)). |
| `succeeded` | Todas as etapas passaram (ou a pessoa seguiu adiante após a última). |
| `canceled` | Cancelada por uma pessoa. |
| `failed` | Reservado; hoje as falhas levam a `awaiting_decision`. |

### O merge do PR

Com um pipeline que faz o merge do PR (`auto_merge`, [ADR 0045](../adr/0045-merge-automatico-do-pr.md)),
uma tarefa `succeeded` ganha um `merge_state`, à parte do status:

```
succeeded ──► waiting_checks ──(checks passaram, sem conflito)──► merged
                 │      ▲
                 │      └──(a correção passou: succeeded de novo)
                 ├──(check falhou ou conflito, correções < máximo)──► fixing (tarefa running, "Correção N")
                 └──(correções esgotadas, host recusou, PR fechado, 6 h)──► blocked ──(retry_merge)──► waiting_checks
```

Sem uma integração que deixe a plataforma chamar o host, a tarefa termina já em
`blocked`. Uma correção pedida por uma pessoa limpa o estado, que volta quando a tarefa
termina de novo; cancelar a tarefa durante `waiting_checks` ou `fixing` também o limpa.

Entrar em `awaiting_decision` e terminar (`succeeded`, `failed`, `canceled`) gera, além do
toast e da notificação do navegador, uma notificação guardada na caixa do criador e do
dono da decisão; sem nenhum dos dois no workspace, vai para os admins
([ADR 0044](../adr/0044-central-de-notificacoes.md)).

## Etapa (tentativa: `StageRun`)

Cada tentativa é um `StageRun` com um job. Quando o job termina, o gate decide:

| Resultado do job | Gate | Tentativa | Tarefa | Questionário |
|---|---|---|---|---|
| `succeeded`, saída `status: ok`, artefato e gates atendidos | `:passed` | `passed` | próxima etapa, sem aprovação ([ADR 0018](../adr/0018-etapas-autonomas.md)); `succeeded` se era a última | — |
| o mesmo, mas uma regra da etapa casa com a saída estruturada | `{:paused, regra}` | `passed` | `awaiting_decision` | nenhum |
| `succeeded`, saída `status: bloqueado` com `perguntas` válidas ou `opcoes` | `{:blocked, resumo}` | `blocked` | `awaiting_decision` (sem retentativa) | do agente |
| `succeeded`, saída `status: bloqueado` sem nada a perguntar | `{:blocked, resumo}` | `blocked` | `awaiting_decision` (sem retentativa) | da análise (se ligada) |
| `failed`, sem saída estruturada, sem artefato ou com um gate não atendido, com tentativas sobrando | `{:retry, erro}` | `failed` | nova tentativa da mesma etapa, com feedback | — |
| o mesmo, sem tentativas sobrando | `{:exhausted, erro}` | `failed` | `awaiting_decision` | da análise (se ligada) |
| `canceled` | `:canceled` | `canceled` | `canceled`; `awaiting_decision` se foi uma interrupção (`pause_requested`) | — |

Uma pausa por orçamento ou a pedido (`pause_requested`) também não tem questionário.

Um job perdido porque o runner reiniciou, caiu ou se atualizou (reconciliação no join,
protocolo §4.6) **não é tentativa**:

| Evento | Tentativa | Depois |
|---|---|---|
| job de etapa perdido, abaixo do limite de perdas | `lost` ("Perdida (runner)") | a etapa roda de novo na **mesma** tentativa (`requeue + 1`), sem gate e sem análise |
| o mesmo, no limite (`max_lost_requeues`, 3) | `lost` | `awaiting_decision` com o motivo da perda, sem análise |

Ver a [ADR 0043](../adr/0043-runner-resiliente-a-reinicios.md).

**Verificações da plataforma.** Numa etapa que entrega (git, entrega `commit` ou `pr`,
fora de grupo), o runner roda antes dos gates as verificações do contrato
([ADR 0033](../adr/0033-contrato-entre-harness-e-agente.md)). Elas voltam como gates com
`"platform": true`: uma que falha é um erro da tentativa, com a mensagem como feedback.

**Gates e regras.** Os gates são comandos que o runner roda depois do agente, cada um
devendo passar ou falhar. Um gate não atendido é um erro da tentativa. As regras
(`campo == valor` ou `campo != valor`) leem a saída estruturada de uma etapa que
passou; a primeira que casa pausa a tarefa.

**Feedback.** Uma tentativa que segue outra que falhou (automática ou por
`retry_stage`) recebe no prompt o erro, o resumo que a anterior deu e a saída dos
gates não atendidos. O feedback fica no `StageRun` (`feedback`).

## Fila e passos em paralelo

- **Fila (`queued`):** com um limite de tarefas simultâneas no workspace, uma tarefa
  criada além dele entra como `queued` e começa quando outra deixa de rodar (termina
  ou pausa). Cancelar uma tarefa na fila a encerra direto.
- **Origem numa proposta:** `create_task` também roda quando uma proposta de tarefa
  auto-aprovada termina ([ADR 0031](../adr/0031-auto-aprovacao-da-tarefa-escrita-com-ia.md)).
  A tarefa nasce `running` ou `queued` como qualquer outra, com `proposal_job_id`
  apontando para a proposta; uma proposta gera uma tarefa no máximo.
- **Passos em paralelo:** etapas seguidas com o mesmo `group` formam um passo. Elas
  começam juntas, e cada uma passa pelo gate e retenta sozinha. O passo fecha quando
  nenhuma roda mais:
  - todas passaram: o próximo passo, ou uma pausa se alguma casa com uma regra;
  - alguma bloqueou ou esgotou as tentativas: `awaiting_decision` com o motivo de
    cada uma. As perguntas das etapas bloqueadas se juntam num questionário (cada uma
    marcada com a sua etapa, `"etapa"`); sem nenhuma pergunta, a plataforma pede a
    análise (se o pipeline a tiver ligada).

  A `current_stage` aponta para a primeira etapa do passo. `retry_stage` repete as
  que não passaram, e `advance` vai para o passo seguinte.

## Decisões

Valem só em `awaiting_decision`:

- `retry_stage(task, instruções)`: nova tentativa da etapa atual, com número
  `última + 1` e as instruções acrescentadas ao prompt.
- `advance(task, instruções)`: primeira tentativa da próxima etapa, com as instruções.
  Depois da última etapa, a tarefa vira `succeeded`.
- `answer(task, respostas, instruções)` ("Responder e continuar"): exige uma resposta por
  pergunta do `decision_questionnaire` e repete a etapa como `retry_stage`. O `Decision`
  guarda `questions` e `answers`; a nova tentativa os grava em `StageRun.answers` e os
  recebe no prompt ("Respostas da pessoa às suas perguntas").
- `advance` aceita respostas parciais (`answers:`), entregues à etapa seguinte.
- `cancel_task(task)`: `canceled`.

## Fora de uma pausa

- `redo_from(task, índice, instruções, runner_id:)`: em qualquer estado menos
  `running`, roda de novo a etapa `índice` (com as instruções) e as seguintes.
- `correct(task, prompt, runner_id:)`: numa tarefa encerrada, acrescenta a etapa
  "Correção N" ao fim de `task.stages`, com o template de correção, o prompt da pessoa
  nas instruções e os gates, tentativas, modelo e timeout da última etapa. Ela roda e
  entrega como qualquer etapa. O `Decision` tem `action: :correct`. Com
  `merge_fix: true` (o merge automático), conta em `merge_fixes` e deixa a tarefa em
  `fixing`.
- `retry_merge(task, pessoa)`: num merge `blocked` de uma tarefa `succeeded`, volta a
  esperar os checks, com as correções contadas do zero.
- `interrupt(task)`: numa tarefa `running`, marca `pause_requested` e cancela o job. O
  `:canceled` que volta leva a `awaiting_decision` ("foi interrompida"). Um
  `cancel_task` depois zera a pausa e encerra.
- **Runner offline** (`runner_online?: false`): `interrupt` e `cancel_task` encerram o
  job na hora (`Jobs.abandon/2`). Quando o runner volta, ele recebe `job:cancel` para
  esse job (`Jobs.ended_among/2`), e o resultado que mandar é ignorado.
- **Worktree removido:** `redo_from` e `correct` o esquecem, e o runner o monta de novo
  da branch. Durante uma remoção ainda não confirmada, os dois esperam (`:removing`).
- **Outro runner** (`runner_id:`): só quando a branch já foi enviada ao origin por uma
  entrega (`Tasks.switchable?/1`). O novo runner monta o worktree a partir de
  `origin/<branch>`.

Uma decisão reivindica a pausa num `UPDATE` condicional: de duas ao mesmo tempo, a
segunda recebe `:not_awaiting`.

**Análise automática.** Na pausa por falha, ou num bloqueio sem perguntas, com o ajuste
`auto_analysis` do pipeline ligado (o padrão; uma tarefa cujo `pipeline_context` não tem a
chave conta como ligada), a plataforma pede uma proposta `analysis`
(`Tasks.request_analysis/1`) e guarda o job em `decision_analysis_job_id`. Quando ela
termina com perguntas válidas, e a pausa ainda é a mesma, o diagnóstico e as perguntas
viram o `decision_questionnaire` (origem `analise`).
Qualquer decisão, ou `redo_from`, cancela a análise ativa; o início de uma etapa e o fim
da tarefa limpam `decision_questionnaire` e `decision_analysis_job_id`. Com o ajuste
desligado, a pausa leva só o motivo, sem `decision_analysis_job_id`, e a pessoa decide à
mão (ou pede "Sugerir com IA").
