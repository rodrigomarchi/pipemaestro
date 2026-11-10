# 0054 — Retenção por workspace para anexos e eventos do agente

- **Status:** aceita
- **Data:** 09/11/2026
- **Relacionadas:** [ADR 0039](0039-telemetria-do-runner.md), [ADR 0042](0042-arquivos-gerados-pela-etapa.md)

## Contexto

Dois dados do control plane cresciam sem limite e sem escolha do cliente:

- **Os anexos das etapas** (`PipeMaestro.Jobs.JobFile`, em `bytea`). Não havia prazo
  nem cota, e eles só saíam com o job ou a tarefa.
- **O conteúdo dos eventos do agente** (`PipeMaestro.Jobs.Event`), que traz trechos de
  código. O `PipeMaestro.Maintenance` apagava eventos e registros de OpenTelemetry de
  **todos** os jobs terminados havia mais de 30 dias. A opção "manter só metadados",
  pedida no [plano](../plano/01-visao-arquitetura.md) (restrições e questão em aberto 3),
  não existia.

## Decisões

1. **A política é do workspace, como `runner_log_retention_days` (ADR 0039).**
   Quatro campos em `PipeMaestro.Workspaces.Workspace`, editados no backoffice e
   aplicados pelo `PipeMaestro.Maintenance`:

   | Campo | Padrão | Faixa |
   |---|---|---|
   | `job_files_retention_days` | `nil`: sem limite | 1 a 3650 |
   | `job_files_quota_mib` | `nil`: sem cota | positivo |
   | `agent_events_retention_days` | 30 | 1 a 3650 |
   | `agent_events_after_retention` | `metadata` | `metadata` ou `delete` |

   Com os padrões, nenhum anexo de quem já usa perde o conteúdo, e os eventos ficam
   completos pelos mesmos 30 dias de antes. Os membros veem as políticas e o uso na tela
   de Uso, sem editar.
2. **Passado o prazo, um evento guarda só os metadados.** Isso responde à questão em
   aberto 3: o padrão é `metadata`, e `delete` repete o comportamento antigo.
   - O evento fica, com o mesmo `seq` e o mesmo `type`. Do `data` ficam só as chaves de
     `PipeMaestro.Jobs.Event.metadata_keys/0`: o nome da ferramenta (`name`,
     `tool_name`), os identificadores (`id`, `tool_use_id`, `parent_tool_use_id`), as
     durações (`duration_ms`, `duration_api_ms`, `ttft_ms`, `delay_ms`), os tokens
     (`usage`, `model_usage`), o custo (`cost_usd`) e o desfecho (`is_error`, `error`,
     `status`, `subtype`, `stop_reason`, `terminal_reason`).
   - Ficam também `model`, `num_turns`, `pre_tokens`, `attempt` e `max_retries`. São
     números ou identificadores, sem nada que o agente leu ou escreveu, e a linha do tempo
     os mostra.
   - Todo o resto sai: textos, argumentos, `structured_output`, `todos` e decisões.
   - A reescrita é um `UPDATE` em SQL por job (`jsonb_object_agg` sobre as chaves
     permitidas), e a lista de chaves fica num só lugar.
3. **O resumo do job é gravado antes, e é final.**
   - Antes da poda, `Insights.store_summary/1` grava o resumo a partir dos eventos ainda
     inteiros. Uso, Insights e Audit leem colunas e o resumo guardado, nunca os eventos,
     e por isso não mudam.
   - O job ganha `events_pruned_at`. O `Maintenance` não volta a ele, e
     `store_summary/1` não regrava o resumo de um job podado.
   - Os jobs que a poda global antiga já tinha esvaziado são marcados na migração. Um
     job sem eventos nem registros não tem o resumo regravado.
   - A telemetria do job sai nas duas políticas. Cada execução trata no máximo `:batch`
     jobs.
4. **Um anexo vencido perde o conteúdo, não a linha.**
   - Depois de `job_files_retention_days`, contados de `inserted_at`, `content` vira
     `NULL` e o anexo ganha `pruned_at`. Ficam `path`, `byte_size` e `content_type`
     (`PipeMaestro.Jobs.Files.prune/2`).
   - A tarefa mostra o nome com "removido pela retenção", sem link nem miniatura. O
     download responde **410**.
   - Reenviar o mesmo caminho devolve o conteúdo ao anexo.
5. **A cota conta os anexos com conteúdo do workspace inteiro.**
   - O uso é a soma de `byte_size` dos anexos não podados
     (`PipeMaestro.Jobs.Files.workspace_usage/1`).
   - Na transação que já trava o job, um `pg_advisory_xact_lock` por workspace serializa
     a conferência, para que dois uploads simultâneos não passem juntos da cota. A linha
     do workspace não é travada, porque o backoffice a edita.
   - Num `PUT` que substitui um caminho, o arquivo antigo é descontado.
   - Sem cota, não há lock nem soma.
6. **A recusa por cota é um 413 `quota_exceeded`, sem mudar o protocolo.**
   - O `PUT /api/runner/jobs/:job_id/files` responde
     `413 {"error": "quota_exceeded", "quota_bytes"}`. É um 4xx, que o runner não repete.
     Não é 5xx, que ele repetiria.
   - O control plane conta a recusa em `jobs.files_refused_quota`, fora da transação
     desfeita. O job e a tarefa terminam como terminariam.
   - O runner conta os 4xx em `files_failed`. A tentativa da etapa desconta deles os
     recusados e mostra um aviso próprio: "N arquivos recusados: a cota de anexos do
     workspace (X MiB) foi atingida".
   - Runners antigos e novos tratam a resposta igual, por isso `protocol_version` não
     sobe e o runner não muda.

## Consequências

- O cliente escolhe o prazo e o destino dos eventos do agente. Por padrão, depois de 30
  dias, o banco guarda o esqueleto dos eventos em vez de apagá-los: mais linhas, mas
  pequenas.
- O banco deixa de crescer sem limite nos anexos de quem define prazo ou cota.
- O 413 de uma recusa por cota vem do app, com corpo JSON, e não do proxy
  ([guia de deploy](../guias/deploy.md)).
- A cota não está ligada a planos nem a cobrança. Os anexos continuam no Postgres; levar
  os anexos para object storage fica para outra decisão.
