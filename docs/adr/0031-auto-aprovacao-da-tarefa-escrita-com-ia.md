# 0031 — Auto-aprovação da tarefa escrita com IA

- **Status:** aceita
- **Data:** 05/11/2026

## Contexto

Em Tarefas → Escrever com IA, o agente escreve a tarefa e sugere um pipeline
([ADR 0022](0022-propostas-do-agente-como-mecanismo-geral.md)). Depois a pessoa precisava
abrir a proposta, abrir o formulário preenchido e criar a tarefa. Quem já sabe que
pipeline quer, e confia no agente, fazia três cliques a mais e esperava com a página
aberta.

## Decisão

- **O pipeline pode vir no pedido.** O pedido de tarefa aceita `pipeline_id`, validado no
  workspace. Com ele, o prompt cita só esse pipeline, e a proposta o usa mesmo que o
  agente devolva outro nome. Se o pipeline foi apagado depois do pedido, vale a sugestão
  do agente.
- **Auto-aprovação no fim do job, no domínio.** Com `auto_approve`, quando o job da
  proposta termina (`Jobs.finish_job/3` → `Proposals.job_finished/1`), a tarefa é criada
  em nome de quem pediu e iniciada, ou enfileirada além do limite do workspace. Nada
  depende de uma tela aberta. A auditoria registra `task.auto_created`.
- **Quando não cria, diz por quê.** Tarefa não pronta (com as perguntas do agente),
  nenhum pipeline resolvido, quem pediu fora do workspace ou erro de criação (runner
  revogado, diretório não anunciado): a proposta fica para revisão, como antes, e o motivo
  fica guardado em `context["proposal"]["auto_approve"]`. Um erro como "runner offline" não
  se recalcula depois, por isso é guardado.
- **Ligada por padrão só no formulário.** O switch "Criar e iniciar a tarefa sem revisão"
  nasce ligado. No changeset, a ausência vale desligado: pedidos de antes desta decisão e
  a triagem de issues (que não passa pelo formulário) continuam esperando revisão.
- **Uma proposta vira uma tarefa no máximo, garantido no banco.** `tasks.proposal_job_id`
  tem índice único parcial. `Tasks.create_task/4` com `proposal: job` põe o vínculo (fora
  do `cast`, para o formulário não forjá-lo); um segundo término ou um clique manual
  concorrente recebe o erro de unicidade. Não se usa lock na linha do job: `create_task`
  entrega o primeiro job ao runner logo depois do insert, então a tarefa precisa estar
  commitada antes, fora de uma transação externa. `context["proposal"]["created_task_id"]`
  é gravado depois, para a tela; a fonte de verdade é a coluna.

## Consequências

- A tela da proposta mostra "Abrir a tarefa" no lugar de "Revisar e criar a tarefa" e leva
  quem pediu até ela quando a tarefa nasce com a página aberta.
- `/tasks?proposta=<id>` de uma proposta já transformada em tarefa leva à tarefa.
- O protocolo do runner não muda: tudo vive no contexto de controle (`"proposal"`), que não
  chega ao runner.
