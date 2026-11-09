# Integrações com hosts git

> Implementada em `PipeMaestro.Integrations`. Decisões: [ADR 0036](../adr/0036-integracoes-com-hosts-git.md)
> e [ADR 0037](../adr/0037-credencial-git-por-job.md). As issues são uma fonte de tarefa
> (`PipeMaestro.TaskSources`, [ADR 0053](../adr/0053-fontes-de-tarefa.md)); o push, o PR, o
> commit status e o auto-merge são do host git, e não da fonte.

## 1. Modelo de dados

| Esquema | Tabela | Papel |
|---|---|---|
| `Connection` | `integration_connections` | Um host git conectado ao workspace: provedor, `base_url`, `auth_kind` (`token`, `oauth`, `github_app`), `api_mode` (`control_plane`, `runner`), credencial e segredo do webhook cifrados, bot, versão, `status` (`pending`, `active`, `error`) |
| `LinkedRepo` | `integration_repos` | Um repositório da conexão ligado a um projeto (obrigatório ao vincular): `full_name`, branch padrão, webhook (`managed`, `manual`, `failed`), prefixo das labels, `synced_at` |
| `Trigger` | `integration_triggers` | O que dispara uma tarefa no repositório (seção 3) |
| `IssueState` | `integration_issues` | Por issue: o retrato das labels, a última atualização vista, os gatilhos que já dispararam e os comentários já aplicados como comando |
| `Delivery` | `integration_deliveries` | Cada entrega recebida, reconciliada ou reprocessada, com o evento, o status e o motivo |

A tarefa guarda a origem genérica (`source`, `source_id`, `source_url`, `source_ref`, e em
`pending_source_note` a nota de uma decisão), `linked_repo_id` (o repositório do host git
onde a plataforma cuida do PR), `head_sha` (o último commit empurrado) e `issue_feedback`
(o que já foi aplicado no host, de `Integrations`). Nas issues, a origem é `git_issue`: o id
e o link são o link da issue, e `source_ref` traz o `number`.

### A fonte `git_issue`

`PipeMaestro.Integrations.IssueSource` implementa `PipeMaestro.TaskSources.Source` para as
issues do Forgejo e do GitHub:

| Responsabilidade | Callback | Faz |
|---|---|---|
| gatilho | `receive_webhook/4`, `poll/2` | o webhook entra por `Ingest` (a chave é a conexão; sem chave, o App do GitHub); o polling é o `Reconciler` |
| item | `fetch_item/1`, `parse_link/1` | lê a issue com a conexão do repositório vinculado e a normaliza num `Item`; reconhece o link de issue de qualquer host |
| andamento | `task_changed/1`, `triage_finished/1`, `runner_delivery/1`, `pr_reference/1` | `Feedback.sync/1` e `AutoMerge.check/1` para tarefa de repositório vinculado; o comentário da decisão que o runner leva; `Closes <issue>` no PR |
| respostas e comandos | `reply/3` | comenta na issue; os comandos chegam por `Conversation` e valem por `TaskSources.apply_command/3` |

## 2. Eventos normalizados

O webhook de cada provedor vira um `PipeMaestro.Integrations.Event`. Tudo o que não está
na tabela é ignorado com o motivo "evento sem uso".

| `kind` | Forgejo (`X-Forgejo-Event-Type`) | GitHub (`X-GitHub-Event`) |
|---|---|---|
| `:ping` | — | `ping` |
| `:issue_opened` | `issues`, `action: opened` | `issues`, `action: opened` |
| `:issue_labels_changed` | `issue_label` (`label_updated`, `label_cleared`; o payload traz a lista inteira) | `issues`, `labeled` e `unlabeled` |
| `:issue_comment` | `issue_comment`, `created` (`is_pull` num PR) | `issue_comment`, `created` |
| `:issue_closed` | `issues`, `closed` | `issues`, `closed` |
| `:pr_review` | `pull_request_review_approved` e `_rejected` | `pull_request_review`, `submitted` |
| `:pr_closed` | `pull_request`, `closed` (`merged`) | `pull_request`, `closed` (`merged`) |

Assinatura: no Forgejo, `X-Forgejo-Signature`, o HMAC-SHA256 do corpo em hex puro; no
GitHub, `X-Hub-Signature-256`, `sha256=<hex>`. O id da entrega vem de `X-Forgejo-Delivery`
ou de `X-GitHub-Delivery`.

## 3. Gatilhos

| `kind` | Casa quando | Modo da API |
|---|---|---|
| `label` | a label do gatilho foi adicionada (não estava no retrato anterior) | os dois |
| `comment` | o comentário começa com o comando (`/pipemaestro`), numa issue sem tarefa ativa; `/pipemaestro <pipeline>` escolhe o pipeline | só `control_plane` |
| `opened` | uma issue (não um PR) foi aberta por alguém que não é o bot | só `control_plane` |

Cada gatilho tem `mode` (`triage`, com a IA escrevendo a tarefa, ou `task`, direta),
`auto_approve`, pipeline (opcional na triagem), `author_policy` (`writers` ou `anyone`;
este com confirmação e só com triagem), `max_per_hour` e a pessoa em nome de quem a tarefa
nasce. Com `writers`, a permissão é conferida em quem comentou, abriu a issue ou pôs a
label.

Um gatilho dispara uma vez por issue. Tirar a label e pôr de novo dispara outra vez, desde
que a issue não tenha tarefa nem triagem em andamento.

## 4. Processamento de uma entrega

```
received ──► processed     (criou a triagem ou a tarefa, ou aplicou um comando)
   ├──────► ignored        (o motivo vai em `outcome`)
   ├──────► waiting_runner (o repositório sem projeto, ou o projeto sem runner ou sem a pasta;
   │                        a reconciliação tenta de novo, e a label continua contando como nova)
   └──────► failed         (erro da API ou da criação; a reconciliação tenta de novo)
```

Os passos, em ordem; o primeiro que encerra deixa o motivo:

1. o evento é reconhecido;
2. não foi o próprio bot que o causou;
3. o repositório está vinculado;
4. atualiza o `IssueState` e calcula as labels adicionadas;
5. um comentário com comando numa issue (ou PR) com tarefa vai para os comandos (seção 6);
   um evento do PR de uma tarefa vai para a seção 7;
6. algum gatilho ligado casa;
7. quem causou o evento tem permissão de escrita (com `writers`; para a label, quem a pôs);
8. o gatilho não passou do limite por hora;
9. a issue não tem tarefa nem triagem em andamento;
10. relida pela API, a issue continua aberta (`control_plane`);
11. o repositório tem um projeto e o projeto pode receber trabalho (`Projects.health/2`): o runner dele offline não impede
    nada, o job espera por ele; projeto sem runner, ou cujo runner não oferece mais a pasta,
    deixa a entrega `waiting_runner`, e o comentário de status diz o que falta;
12. cria a triagem ou a tarefa a partir do item da issue (`TaskSources.start/3`, com o projeto
    do repositório e o pipeline do gatilho), registra o disparo e reconhece na issue (reação, label e
    comentário de status).

Um erro no processamento deixa a entrega `failed` com a mensagem. A reconciliação tenta de
novo as `waiting_runner` e `failed` (até 5 vezes, no último dia) e as que ficaram
`received` por mais de dez minutos. As entregas saem depois de 30 dias
(`PipeMaestro.Maintenance`).

## 5. Retorno no host

Labels, com o prefixo do repositório (padrão `pipemaestro`):

| Label | Tarefa |
|---|---|
| `pipemaestro` | o gatilho; nunca é removida pela plataforma |
| `pipemaestro:triando` | triagem ou na fila |
| `pipemaestro:em-andamento` | `running` |
| `pipemaestro:aguardando-decisao` | `awaiting_decision` |
| `pipemaestro:pronto` | `succeeded` |
| `pipemaestro:cancelada` | `canceled` |

O comentário de status é um só por issue, marcado com `<!-- pipemaestro:status -->` e
editado no lugar: nasce quando a issue é reconhecida e passa para a tarefa (estado, etapas,
links da tarefa e do PR e, numa decisão, o motivo e as perguntas). Apagado, ele é escrito
de novo. Comentários novos, que notificam, só quando a tarefa espera uma decisão
(mencionando quem abriu a issue), quando o PR fica pronto, quando ela é cancelada e quando
a triagem termina sem criar a tarefa.

Commit status no `head_sha`, um por etapa, com `context` `pipemaestro/<chave da etapa>`:
`success` para a que passou, `pending` para a atual, `warning` para a pausada, `failure` para
a esgotada e `error` quando a tarefa foi cancelada. No GitHub, um check run por etapa,
atualizado no lugar; o de uma etapa parada oferece "Refazer etapa".

## 6. Comandos em comentário

O texto e a leitura dos comandos são de `PipeMaestro.TaskSources.Commands`, comuns a
qualquer fonte; a aplicação é de `TaskSources.apply_command/3`.

Valem numa issue (ou no PR) de uma tarefa, só de quem tem permissão de escrita. A primeira
linha que começa com o comando do gatilho é a lida.

| Comando | Estado da tarefa | Efeito |
|---|---|---|
| `/pipemaestro seguir [instruções]` | `awaiting_decision` | segue para a próxima etapa |
| `/pipemaestro refazer [instruções]` | `awaiting_decision` | nova tentativa da etapa |
| `/pipemaestro responder` + respostas `1. ...` | com questionário | responde as perguntas, na ordem |
| `/pipemaestro pausar` | `running` | pausa depois da etapa |
| `/pipemaestro cancelar` | ativa | cancela |
| `/pipemaestro corrigir <pedido>` | `succeeded` ou `canceled` | nova etapa "Correção N" |

Um comando aplicado ganha uma reação 👍 e fica na decisão como `decided_via` (provedor e
login); um inválido para o estado recebe uma resposta com os comandos válidos.

## 7. Eventos do PR

- Review pedindo mudanças num PR de tarefa `succeeded`, de quem tem escrita: nova etapa
  "Correção N" com o texto do review e os comentários de linha como pedido.
- "Refazer etapa" no check run (GitHub), de quem tem escrita: nova tentativa da etapa.
- PR fechado com merge: o comentário de status diz "integrado".

### Merge automático

Com `auto_merge` no pipeline ([ADR 0045](../adr/0045-merge-automatico-do-pr.md)), depois da
última etapa a plataforma (`PipeMaestro.Integrations.AutoMerge`) olha o PR a cada minuto
e a cada mudança da tarefa:

- **Espera** pelo PR pronto, na head igual ao último commit da tarefa, com `mergeable`
  calculado e sem check rodando.
- **Os checks** são os status de commit (o status combinado, `GET
  /commits/:sha/status`) e, no GitHub, os check runs (`GET /commits/:sha/check-runs`).
  Ficam de fora os `pipemaestro/*` da própria plataforma.
- **O merge** é `PUT /pulls/:n/merge` com `merge_method` e `sha` no GitHub, e `POST
  /pulls/:n/merge` com `Do` e `head_commit_id` no Forgejo.
- **Check vermelho ou conflito** (visto duas vezes na mesma head) vira uma etapa
  "Correção N" com o que falhou, até `max_merge_fixes`. Depois disso, o merge fica
  bloqueado e quem cuida da tarefa é avisado.
- **Recusa do host, PR fechado ou 6 horas de espera** bloqueiam o merge, sem correção.
