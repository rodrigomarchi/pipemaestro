# 0045 — Merge automático do PR

- **Status:** aceita
- **Data:** 07/11/2026
- **Relacionadas:** [ADR 0013](0013-distribuicao-e-entrega-no-git.md), [ADR 0027](0027-entrega-em-pr-no-forgejo.md), [ADR 0032](0032-sem-ruas-sem-saida.md), [ADR 0036](0036-integracoes-com-hosts-git.md), [ADR 0044](0044-central-de-notificacoes.md)

## Contexto

Com `delivery: pr`, a tarefa termina com o PR pronto, e uma pessoa espera o CI do
repositório e faz o merge. O fluxo para aí: mesmo quando nada precisa de revisão, a
issue só vira código na `main` com alguém olhando o PR. E um CI que falha depois do
pipeline volta para uma pessoa, que pede uma correção à mão.

## Decisão

- **É uma opção do pipeline**, só com a entrega em PR:
  - `auto_merge`;
  - `merge_method` (`squash`, o padrão; `merge` ou `rebase`);
  - `max_merge_fixes` (3 por padrão, de 0 a 10).

  O pipeline guarda os três no contexto que a tarefa leva quando começa. Uma proposta
  do agente não liga o merge, como não põe teto de custo: a revisão de um pipeline
  mantém o que ele já tinha.
- **Quem espera e faz o merge é a plataforma, pela API do host**
  (`PipeMaestro.Integrations.AutoMerge`), e não o auto-merge nativo do GitHub ou do
  Forgejo. Com o nativo, o GitHub faria o merge na hora se o repositório não tivesse
  checks obrigatórios. Pela plataforma, a regra é a mesma nos dois hosts e vale para
  todos os checks, e cada passo fica na tarefa, na auditoria e nas notificações.
- **Só vale para um repositório vinculado por uma integração que deixa a plataforma
  chamar o host** (`Integrations.keeps_pull_request?/1`). Sem ela, a tarefa termina
  com o merge bloqueado e o motivo.
- **O estado do merge é separado do status da tarefa.** A máquina de estados não muda:
  a tarefa continua `succeeded`, e `merge_state` diz onde o merge está:
  - `waiting_checks`;
  - `fixing`;
  - `merged`;
  - `blocked`, com `merge_reason`.
- **O que a plataforma olha, a cada minuto** (`AutoMergeWorker`) **e a cada mudança da
  tarefa** (`FeedbackWorker`):
  - **Espera** enquanto:
    - o PR é rascunho;
    - a head do PR não é o último commit da tarefa;
    - o host ainda calcula se o PR faz merge;
    - algum check está rodando.
  - **Os checks** são os status de commit e, no GitHub, os check runs. Os
    `pipemaestro/*` da própria plataforma não contam. Sem nenhum check, vale como todos
    passados.
  - **O merge** usa a head como commit esperado: um push no meio do caminho faz o host
    recusar, em vez de integrar o que ninguém viu.
- **Um check que falha ou um conflito voltam ao pipeline.** A tarefa ganha uma etapa
  "Correção N" (`Tasks.correct/3` com `merge_fix: true`):
  - o pedido lista os checks que falharam, com resumo e link;
  - num conflito, o pedido é trazer a base e resolvê-lo;
  - a correção é registrada como `via: "merge automático"`;
  - quando ela passa, a tarefa volta a esperar os checks.

  Depois de `max_merge_fixes` correções, o merge fica bloqueado e quem cuida da tarefa
  é avisado. O Forgejo diz que um PR não faz merge enquanto ainda o verifica depois de
  um push, por isso um conflito só conta quando aparece duas vezes na mesma head.
- **Sem correção quando nenhuma etapa resolveria.** O merge fica bloqueado, sem nova
  etapa, quando:
  - o host recusa o merge (proteção de branch, head que mudou);
  - o PR foi fechado sem o merge;
  - os checks não terminam em 6 horas.

  Na página da tarefa, "Tentar o merge de novo" volta a esperar os checks, com as
  correções contadas do zero.
- **Avisos:** `task_merged` e `task_merge_blocked` entram na caixa de notificações
  ([ADR 0044](0044-central-de-notificacoes.md)). No host, o comentário de status diz
  "integrado".

## Consequências

- Um pipeline com `auto_merge` leva uma issue até a `main` sem ninguém, quando o CI
  passa. A revisão humana passa a ser escolha do pipeline (uma etapa ou uma regra que
  pede decisão), não uma parada obrigatória no fim.
- O GitHub App precisa da permissão *Commit statuses: Read*
  ([`guias/github-app.md`](../guias/github-app.md)). Um token do Forgejo precisa de
  escrita no repositório, que a entrega em PR já pedia.
- A espera é por polling. Webhooks de status e de check suite poderiam adiantá-la, mas
  o polling continua sendo a fonte da verdade.
