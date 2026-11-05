# 0032 — Sem ruas sem saída

- **Status:** aceita
- **Data:** 05/11/2026

## Contexto

Uma tarefa terminou sem PR porque a entrega falhou. A plataforma não oferecia como pedir
"abra o PR" ou "corrija isso" no mesmo worktree, e a correção foi feita à mão, pelo
terminal. Não dá para prever tudo o que pode dar errado: o PR com conflito, o CI do PR
quebrado, a revisão pedindo mudança, o runner que some.

Antes, estas eram as ruas sem saída:
- **Uma tarefa encerrada** só podia ser refeita a partir de uma etapa, sem instruções, ou
  recomeçada do zero.
- **Um worktree removido** impedia refazer.
- **Um job num runner que não volta mais** deixava a tarefa "rodando" para sempre: o
  cancelamento esperava a confirmação do runner.
- **Uma etapa travada** só parava cancelando a tarefa inteira.
- **A tarefa ficava presa** ao runner em que nasceu.

## Decisão

**Toda tarefa parada ou encerrada aceita um novo prompt, que roda no mesmo worktree e
na mesma branch e passa pela entrega de sempre.**

- **Corrigir com um prompt** (`Tasks.correct/3`): numa tarefa encerrada, o prompt vira
  uma etapa nova, "Correção N", acrescentada ao fim da tarefa.
  - É uma etapa, e não um job avulso, para herdar tudo: os artefatos anteriores no
    prompt, os gates, as tentativas, a análise da falha, o questionário e a entrega.
    Como é a última etapa, ela deixa o PR pronto, com a correção no checklist.
  - Os gates, as tentativas, o modelo e o timeout vêm da última etapa da tarefa.
- **Refazer a partir de uma etapa** aceita instruções.
- **Interromper uma etapa** (`Tasks.interrupt/2`) cancela o job e leva a tarefa a
  `awaiting_decision`, com as opções de uma pausa.
- **Runner offline:** interromper e cancelar encerram o job na hora
  (`Jobs.abandon/2`). Quando o runner volta, ele recebe `job:cancel` para esse job, e o
  resultado que mandar é ignorado.
- **Worktree removido:** refazer e corrigir o esquecem, e o runner o monta de novo a
  partir da branch local ou, se ela não existe, de `origin/<branch>`.
- **Outro runner:** refazer e corrigir podem continuar em outro runner do workspace que
  tenha o diretório, mas só quando uma entrega já enviou a branch ao origin. Sem isso, o
  trabalho está só na máquina antiga.

O protocolo não muda: `job:cancel` e o worktree por tarefa já existiam.

## Consequências

- Uma tarefa pode ter mais etapas do que o pipeline de onde veio. `task.stages` é a
  foto da tarefa, e as correções entram nela.
- Uma tarefa `succeeded` pode voltar a `running`. Telas e contagens que tratam
  `succeeded` como definitivo passam a ver a tarefa de novo em andamento enquanto a
  correção roda.
- Cancelar com o runner offline não para o processo do agente até ele voltar. O que o
  agente fizer nesse meio-tempo fica no worktree e não é entregue.
