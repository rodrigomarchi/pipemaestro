# 0056 — Fontes de tarefa

- **Status:** aceita
- **Data:** 09/11/2026
- **Plano:** [`01-visao-arquitetura.md`](../plano/01-visao-arquitetura.md), seção 4.1
- **Relacionadas:** [ADR 0036](0036-integracoes-com-hosts-git.md), [ADR 0034](0034-o-projeto-e-a-escolha-de-onde-o-trabalho-roda.md)
- **Spec:** [`integracoes.md`](../specs/integracoes.md)

## Contexto

De onde vem a tarefa (a fonte) e onde fica o código (o projeto e o host git) estavam
misturados na integração com hosts git
([ADR 0036](0036-integracoes-com-hosts-git.md)). A tarefa tinha campos próprios de issue
(`issue_url`, `issue_number`, `linked_repo`, `pending_issue_comment`), e o motor
(`PipeMaestro.Tasks`) e as propostas faziam alias de `LinkedRepo` e `Trigger` e liam o JSON
de uma issue. A visão do produto já previa uma camada de adaptadores de fonte e um modelo
interno da tarefa independente dela. Sem essa camada, uma fonte sem código (Jira, Linear,
ClickUp) exigiria mexer no motor.

## Decisões

1. **A fonte é um behaviour** (`PipeMaestro.TaskSources.Source`), registrado por chave em
   `config :pipe_maestro, PipeMaestro.TaskSources, sources: %{...}`. Suas responsabilidades:
   - **receber o gatilho**: webhook (`receive_webhook/4`: verificar, registrar e processar
     fora da requisição, como `Delivery` e `Ingest`) e/ou polling (`poll/2`, como o
     `Reconciler`). Uma fonte tem ao menos um dos dois. Quem precisa de um relógio traz o
     próprio processo para `application.ex`;
   - **ler e normalizar o item** (`fetch_item/1`) num `PipeMaestro.TaskSources.Item`
     independente da fonte: título, descrição, autor, labels, prioridade, link, a fonte e o
     id externo. `parse_link/1` reconhece o link que uma pessoa cola numa tarefa;
   - **refletir o andamento**: `task_changed/1` a cada mudança de uma tarefa da fonte
     (comentário de status, labels ou campo de status), `triage_finished/1` quando uma
     triagem termina sem tarefa, `runner_delivery/1` (o que o runner entrega pela fonte com
     uma etapa) e `pr_reference/1` (a linha do PR que nomeia a origem);
   - **receber respostas e comandos**: `seguir`, `refazer`, `responder`, `pausar`,
     `cancelar` e `corrigir` (`PipeMaestro.TaskSources.Commands`) chegam pelo gatilho da
     fonte e vão, por `TaskSources.apply_command/3`, às mesmas funções da tela, em nome do
     dono da tarefa. `reply/3` responde a uma pessoa na fonte.
2. **O motor não conhece a fonte.** `Tasks` e `Proposals` falam só com `TaskSources`, o
   `Item` e a `Origin`. A tarefa guarda `source` (a chave), `source_id` (o id externo),
   `source_url` e `source_ref` (o que a fonte guarda do item, opaco ao motor). O sinal de
   mudança é `"tasks:sourced"`, com `{:source_task_updated, task}`, para qualquer tarefa
   com fonte; o `PipeMaestro.TaskSources.Dispatcher` o leva à fonte certa. Uma proposta
   guarda a origem no input da triagem, em `"origin"`. O formato anterior (`issue_url`,
   `linked_repo_id`, `issue_number`) continua lido como a origem `git_issue`.
3. **Fonte ≠ host git.** Push, PR, commit status, credencial git e auto-merge continuam no
   host git do projeto (`PipeMaestro.Integrations`), nunca na fonte. O `linked_repo_id` da
   tarefa fica como dado do host git, dado pela fonte quando ela conhece um repositório; o
   motor só pergunta a `Integrations` quem cuida do PR (`pull_request_keeper/1`) e não decide
   nada por ele. Ligar o host git ao projeto, em vez de à origem, mudaria o comportamento de
   tarefas criadas à mão num projeto com repositório vinculado e fica fora desta decisão.
4. **Uma fonte aponta para um projeto do workspace.** O gatilho de uma fonte sem código diz
   em qual projeto a tarefa roda (`target.project_id`), e o projeto escolhe runner e pasta
   ([ADR 0034](0034-o-projeto-e-a-escolha-de-onde-o-trabalho-roda.md)). Nas issues de host
   git, o projeto continua vindo do `LinkedRepo`.
5. **As issues do Forgejo e do GitHub são a primeira fonte**
   (`PipeMaestro.Integrations.IssueSource`, chave `git_issue`). Ela passa pela interface
   nova reaproveitando `Ingest`, `Reconciler`, `Feedback`, `Conversation` e `AutoMerge`.
6. **`issue_feedback` e `pending_issue_comment`.**
   - `pending_issue_comment` vira `pending_source_note`: o motor escreve o resumo da
     decisão e a fonte decide como levá-lo (a das issues o entrega pelo runner).
   - `issue_feedback` mantém o nome e é de `Integrations`: guarda o que já foi aplicado no
     host (label, comentário de status, avisos) e também o estado do PR que o auto-merge
     lê (`pr_number`, `merged`, `conflict_sha`). O motor não o lê nem o escreve. Separar o
     estado da fonte do estado do PR pediria reescrever `Feedback.sync/1`, o que não é desta
     decisão.

## Migração

A migração de `AddTaskSource` acrescenta as colunas da origem e preenche, nas tarefas com
`issue_url`, a origem `git_issue` (id e link iguais ao `issue_url`, `{"number": n}` em
`source_ref`), além do `pending_source_note`. Tarefas criadas à mão só com `issue_url`
ganham origem também. As colunas antigas ficam, sem uso: o deploy migra antes de subir a
versão nova, e a versão em execução nesse intervalo ainda as lê. Removê-las é uma migração
posterior.

## O que fica fora

- Implementar Jira, Linear ou ClickUp, ou uma tela para configurar fontes.
- Mudar gatilhos, guardas, reconciliação, feedback, comandos ou auto-merge.
- Tirar de `Integrations` o push, o PR, o commit status ou o auto-merge.
- O runner e o `protocol`: o formato da entrega ao runner (`issue_comment`) não muda.

## Consequências

- Uma fonte nova implementa o behaviour e se registra pela configuração, sem tocar em
  `Tasks`, `Proposals` nem no schema da tarefa. Um teste com uma fonte fictícia prova isso.
- As tarefas criadas depois do deploy não preenchem as colunas antigas. Um rollback do
  código as veria sem `issue_url`.
