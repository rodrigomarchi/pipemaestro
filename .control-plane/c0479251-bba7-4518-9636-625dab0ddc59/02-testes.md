# Etapa 2 — Testes que falham

Testes novos que descrevem o comportamento do plano (`01-plano.md`), sem implementação.
Só o app `pipe_maestro` ganha testes: nenhuma tela muda, então não há spec Playwright novo
(os `e2e/tests/integrations-*.spec.ts` e `task-*.spec.ts` existentes provam "nenhuma
mudança visível" na etapa de validação).

## Arquivos

| Arquivo | O que prova | Critério |
|---|---|---|
| `apps/pipe_maestro/test/pipe_maestro/task_sources_test.exs` | Uma **fonte fictícia** (`FakeSource`, definida só no teste, `@behaviour PipeMaestro.TaskSources.Source` + `@impl`) registrada por `Application.put_env` (`async: false`). Com ela, sem tocar no motor: o registro (`fetch/1`, `sources/0`, `"git_issue"` → `IssueSource`); o webhook roteado pela chave (`receive_webhook/4`, `{:error, :not_found}` para fonte desconhecida); a **criação** a partir do `Item` (`start/3` modo `"task"`: `source`, `source_id`, `source_url`, `source_ref`, projeto, pipeline e pessoa do alvo, prompt `"descrição\n\nTicket: url"`, título como pedido quando sem descrição, `{:error, :no_acting_user}`); `active?/3` e `Tasks.active_for_source?/3`; a **triagem** (modo `"triage"`: origem no input via `Origin.from_input/1`, `:already_triaging`, `triage_finished/1` chega à fonte); o **reflexo** (`Tasks.subscribe(:sourced)` recebe `{:source_task_updated, task}`, o `Dispatcher` chama `task_changed/1` a cada mudança, inclusive o cancelamento; tarefa sem fonte não sinaliza); o PR com o `pr_reference/1` da fonte (sem `Closes`); os **comandos** (`Commands.parse/2` + `apply_command/3`: `refazer` volta a rodar e grava a decisão com `decided_via`, `seguir` fora de hora devolve "A tarefa não espera uma decisão agora.", `cancelar` cancela); a nota da decisão em `pending_source_note`; `fetch_item/1` e `reply/3` da fonte. | 2, 4 |
| `apps/pipe_maestro/test/pipe_maestro/integrations/issue_source_test.exs` | `IssueSource` declara o behaviour; `parse_link/1` (link de issue → `Origin` `git_issue` sem número nem repositório; link inválido → a mensagem de hoje); `TaskSources.parse_link/1`; `fetch_item/1` lê a issue no FakeForgejo e normaliza (`kind: "Issue"`, autor, labels, `ref.number`, `linked_repo_id`); uma tarefa de issue vinculada guarda `linked_repo_id` e `source_ref["number"]` e o prompt `"corpo\n\nIssue: url"` de hoje; `pr_reference/1` = `"Closes url"`; `runner_delivery/1` com e sem nota (o mesmo `"issue_comment"` do protocolo); `task_changed/1` de tarefa sem repositório não faz nada. | 2, 6 |
| `apps/pipe_maestro/test/pipe_maestro/task_sources/origin_test.exs` | `Origin.to_input/1` ↔ `from_input/1` (ida e volta em JSON); compatibilidade com propostas antigas (`issue_url` + `linked_repo_id` + `issue_number`, e só `issue_url`); input sem origem → `nil`. | 3 (propostas), 6 |
| `apps/pipe_maestro/test/pipe_maestro/task_sources/origin_backfill_test.exs` | A migração `*_add_task_source.exs` (`PipeMaestro.Repo.Migrations.AddTaskSource.backfill_sql/0`, uma instrução ou uma lista): tarefa de issue vinculada ganha `git_issue`, URL, `{"number": 42}`, a nota copiada de `pending_issue_comment` e mantém `linked_repo_id`; tarefa à mão só com `issue_url` ganha origem sem número; tarefa sem issue fica sem origem; rodar duas vezes não muda nada. Padrão de `runner_backfill_test.exs`; o `setup_all` não falha se a migração ainda não existe. | 5 |

Os nomes e assinaturas seguem o plano: `TaskSources.{fetch/1, sources/0, receive_webhook/4,
start/3, active?/3, parse_link/1, triage_finished/1, apply_command/3}`,
`TaskSources.{Item, Origin, Commands, Dispatcher}`, `Tasks.active_for_source?/3`,
`Tasks.subscribe(:sourced)`, campos `source`, `source_id`, `source_url`, `source_ref`,
`pending_source_note` na tarefa. O alvo de `start/3` é um mapa
`%{mode, project_id, pipeline_id, acting_user_id, auto_approve}`.

Os testes existentes **não foram tocados**: os ajustes mecânicos de nome (`issue_url` →
`source_url`, `create_from_linked_issue` → `create_from_item`, `subscribe(:linked)` →
`subscribe(:sourced)`, `Integrations.Commands` → `TaskSources.Commands`, etc., lista na
seção 7 do plano) ficam para a implementação, junto com a mudança que os pede. Os vizinhos
continuam passando porque nenhum arquivo deles mudou.

## Execução

```
mix format                     # ok; mix format --check-formatted → 0
mix test apps/pipe_maestro/test/pipe_maestro/task_sources_test.exs \
         apps/pipe_maestro/test/pipe_maestro/task_sources \
         apps/pipe_maestro/test/pipe_maestro/integrations/issue_source_test.exs
Result: 0/29 passed
```

Compila (só avisos de módulo e função ainda inexistentes, esperados) e cada teste falha na
primeira referência ao que falta. Trechos:

```
TaskSourcesTest — o registro, o webhook, a criação, a triagem, os comandos
  ** (UndefinedFunctionError) function PipeMaestro.TaskSources.fetch/1 is undefined (module PipeMaestro.TaskSources is not available)
  ** (UndefinedFunctionError) function PipeMaestro.TaskSources.receive_webhook/4 is undefined (module PipeMaestro.TaskSources is not available)
  ** (UndefinedFunctionError) function PipeMaestro.TaskSources.Item.__struct__/1 is undefined (module PipeMaestro.TaskSources.Item is not available)
     code: task = start_task(ctx)   /   task = awaiting(ctx)

TaskSourcesTest — o sinal genérico
  ** (FunctionClauseError) no function clause matching in PipeMaestro.Tasks.subscribe/1
     code: :ok = Tasks.subscribe(:sourced)

IssueSourceTest
  ** (UndefinedFunctionError) function PipeMaestro.Integrations.IssueSource.module_info/1 is undefined (module PipeMaestro.Integrations.IssueSource is not available)
  ** (UndefinedFunctionError) function PipeMaestro.Integrations.IssueSource.parse_link/1 is undefined
  ** (UndefinedFunctionError) function PipeMaestro.TaskSources.Origin.__struct__/1 is undefined
  ** (KeyError) key :source not found        (struct!(Task, source: ...): a tarefa ainda não tem os campos da origem)

OriginTest
  ** (UndefinedFunctionError) function PipeMaestro.TaskSources.Origin.from_input/1 is undefined (module PipeMaestro.TaskSources.Origin is not available)

OriginBackfillTest
  ** (UndefinedFunctionError) function PipeMaestro.Repo.Migrations.AddTaskSource.backfill_sql/0 is undefined (module PipeMaestro.Repo.Migrations.AddTaskSource is not available)
```

Por que é a falha certa: nenhuma falha vem de sintaxe, fixture ou setup (os `setup` com
FakeForgejo, runner, projeto e repositório vinculado rodam). Todas apontam para o que o
plano manda criar: o contexto `TaskSources` e suas structs, `IssueSource`, o sinal
`:sourced`, os campos da origem em `Task` e a migração com o backfill. O `KeyError` de
`struct!(Task, source: ...)` é o schema da tarefa ainda sem os campos novos.
