# Integrações com hosts git

> Implementada em `PipeMaestro.Integrations`. Decisões: [ADR 0034](../adr/0034-integracoes-com-hosts-git.md)
> e [ADR 0035](../adr/0035-credencial-git-por-job.md).

## 1. Modelo de dados

| Esquema | Tabela | Papel |
|---|---|---|
| `Connection` | `integration_connections` | Um host git conectado ao workspace: provedor, `base_url`, `auth_kind` (`token`, `oauth`, `github_app`), `api_mode` (`control_plane`, `runner`), credencial e segredo do webhook cifrados, bot, versão, `status` (`pending`, `active`, `error`) |
| `LinkedRepo` | `integration_repos` | Um repositório da conexão ligado a um projeto: `full_name`, branch padrão, webhook (`managed`, `manual`, `failed`), prefixo das labels, `synced_at` |
| `Trigger` | `integration_triggers` | O que dispara uma tarefa no repositório (seção 3) |
| `IssueState` | `integration_issues` | Por issue: o retrato das labels, a última atualização vista, os gatilhos que já dispararam e os comentários já aplicados como comando |
| `Delivery` | `integration_deliveries` | Cada entrega recebida, reconciliada ou reprocessada, com o evento, o status e o motivo |

A tarefa guarda `linked_repo_id`, `issue_number`, `issue_url`, `head_sha` (o último commit
empurrado) e `issue_feedback` (o que já foi aplicado no host).

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
`auto_approve`, pipeline (opcional na triagem), `author_policy` (`writers` ou `anyone`,
este com confirmação), `max_per_hour` e a pessoa em nome de quem a tarefa nasce.

Um gatilho dispara uma vez por issue. Tirar a label e pôr de novo dispara outra vez, desde
que a issue não tenha tarefa nem triagem em andamento.

## 4. Processamento de uma entrega

```
received ──► processed     (criou a triagem ou a tarefa, ou aplicou um comando)
   ├──────► ignored        (o motivo vai em `outcome`)
   ├──────► waiting_runner (nenhum runner online; a reconciliação tenta de novo)
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
7. o autor tem permissão de escrita (com `writers`);
8. o gatilho não passou do limite por hora;
9. a issue não tem tarefa nem triagem em andamento;
10. relida pela API, a issue continua aberta (`control_plane`);
11. há um runner online que oferece o diretório do projeto (na triagem, com a capability
    `scratch` e o diretório em git);
12. cria a triagem ou a tarefa, registra o disparo e reconhece na issue.

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
editado no lugar: estado, etapas, links da tarefa e do PR e, numa decisão, o motivo e as
perguntas. Comentários novos só quando a tarefa espera uma decisão, quando o PR fica pronto
e quando ela é cancelada.

Commit status no `head_sha`, um por etapa, com `context` `pipemaestro/<chave da etapa>`:
`success` para a que passou, `pending` para a atual, `warning` para a pausada, `failure` para
a esgotada e `error` quando a tarefa foi cancelada. No GitHub, um check run por etapa.

## 6. Comandos em comentário

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

Um comando aplicado ganha uma reação 👍; um inválido para o estado recebe uma resposta com
os comandos válidos.

## 7. Eventos do PR

- Review pedindo mudanças num PR de tarefa `succeeded`: nova etapa "Correção N" com o
  review como pedido.
- PR fechado com merge: o comentário de status diz "integrado".
