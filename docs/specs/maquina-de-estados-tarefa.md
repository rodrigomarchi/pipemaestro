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
                  └──(cancel_task: cancela o job; o runner confirma)
```

| Estado | Significado |
|---|---|
| `running` | Uma tentativa da etapa `current_stage` está na fila ou rodando no runner. |
| `awaiting_decision` | Uma pessoa precisa decidir; o motivo está em `decision_reason`. |
| `succeeded` | Todas as etapas passaram (ou a pessoa seguiu adiante após a última). |
| `canceled` | Cancelada por uma pessoa. |
| `failed` | Reservado; hoje as falhas levam a `awaiting_decision`. |

## Etapa (tentativa: `StageRun`)

Cada tentativa é um `StageRun` com um job. Quando o job termina, o gate decide:

| Resultado do job | Gate | Tentativa | Tarefa |
|---|---|---|---|
| `succeeded`, saída `status: ok`, artefato e gates atendidos | `:passed` | `passed` | próxima etapa, sem aprovação ([ADR 0018](../adr/0018-etapas-autonomas.md)); `succeeded` se era a última |
| o mesmo, mas uma regra da etapa casa com a saída estruturada | `{:paused, regra}` | `passed` | `awaiting_decision` |
| `succeeded`, saída `status: bloqueado` | `{:blocked, resumo}` | `blocked` | `awaiting_decision` (sem retentativa) |
| `failed`, sem saída estruturada, sem artefato ou com um gate não atendido, com tentativas sobrando | `{:retry, erro}` | `failed` | nova tentativa da mesma etapa, com feedback |
| o mesmo, sem tentativas sobrando | `{:exhausted, erro}` | `failed` | `awaiting_decision` |
| `canceled` | `:canceled` | `canceled` | `canceled` |

Um job perdido porque o runner reiniciou (reconciliação no join, protocolo §4.6) conta
como `failed`.

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
- **Passos em paralelo:** etapas seguidas com o mesmo `group` formam um passo. Elas
  começam juntas, e cada uma passa pelo gate e retenta sozinha. O passo fecha quando
  nenhuma roda mais:
  - todas passaram: o próximo passo, ou uma pausa se alguma casa com uma regra;
  - alguma bloqueou ou esgotou as tentativas: `awaiting_decision` com o motivo de
    cada uma.

  A `current_stage` aponta para a primeira etapa do passo. `retry_stage` repete as
  que não passaram, e `advance` vai para o passo seguinte.

## Decisões

Valem só em `awaiting_decision`:

- `retry_stage(task, instruções)`: nova tentativa da etapa atual, com número
  `última + 1` e as instruções acrescentadas ao prompt.
- `advance(task, instruções)`: primeira tentativa da próxima etapa, com as instruções.
  Depois da última etapa, a tarefa vira `succeeded`.
- `cancel_task(task)`: `canceled`.
