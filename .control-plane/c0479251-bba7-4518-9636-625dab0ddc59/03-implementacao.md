# Etapa 3 — Implementação

Implementa o plano (`01-plano.md`) até os testes da etapa 2 passarem. Commits:
`8791fc6` (domínio), `43a8779` (web), `828718e` (testes a mais da fonte de issues).

## O que mudou, por app

### `apps/pipe_maestro`

**Contexto novo `PipeMaestro.TaskSources`** (`lib/pipe_maestro/task_sources.ex`, `task_sources/`):

- `Source`: o behaviour com as quatro responsabilidades.
  - gatilho: `receive_webhook/4` e `poll/2`, opcionais;
  - item: `fetch_item/1` e `parse_link/1` (opcional);
  - andamento: `task_changed/1`, `triage_finished/1`, `runner_delivery/1` e `pr_reference/1`;
  - respostas: `reply/3`.
- `Item`: o item normalizado (título, descrição, autor, labels, prioridade, `kind`, `ref`, `linked_repo_id`).
- `Origin`: o que a tarefa e a proposta guardam. Tem `to_input/1` e `from_input/1`; o `from_input/1` também lê o input antigo, com `issue_url`/`linked_repo_id`/`issue_number`.
- `Commands`: movido de `Integrations.Commands`, sem mudar o texto.
- `Dispatcher`: assina `Tasks.subscribe(:sourced)` e chama `task_changed/1` da fonte. Entra no lugar do `Integrations.FeedbackWorker` em `application.ex`; nos testes fica desligado (`config/test.exs`).
- O contexto em si: o registro por chave, configurado em `config/config.exs` (`"git_issue" => Integrations.IssueSource`), e as funções de despacho:
  - `fetch/1`, `sources/0`, `receive_webhook/5`, `start/3`, `active?/3`, `parse_link/1`;
  - `task_changed/1`, `triage_finished/1`, `runner_delivery/1`, `pr_reference/1`;
  - `apply_command/3` (comando → mesma função da tela, com o motivo de hoje quando não vale) e `owner/1`.

**`Integrations.IssueSource`** (novo, chave `"git_issue"`): implementa o behaviour reaproveitando o que já existia.

| Callback | O que usa |
|---|---|
| `receive_webhook/4` | `Ingest.receive_webhook` / `receive_app_webhook` |
| `poll/2` | `Reconciler.run/2` |
| `fetch_item/1` | `provider.get_issue` |
| `parse_link/1` | `IssueUrl` |
| `task_changed/1` | `Feedback.sync` + `AutoMerge.check` em background, ou `mark_dirty`; nada sem `linked_repo_id` |
| `triage_finished/1` | `Feedback.triage_finished/1` |
| `runner_delivery/1` | o mesmo `"issue_comment"` do protocolo |
| `pr_reference/1` | `"Closes <url>"` |
| `reply/3` | comentário na issue |

Também expõe `item/2`, que monta o `Item` de uma issue lida.

**O motor** (`tasks.ex`, `tasks/task.ex`) não referencia mais `LinkedRepo`, `Trigger`, `IssueState` nem `IssueUrl`, nem o JSON da issue. O `grep` do critério 3 sai vazio.

- O schema troca `issue_url`, `issue_number`, `pending_issue_comment` e `belongs_to :linked_repo` por:
  - `source`, `source_id`, `source_url`, `source_ref`, `pending_source_note`;
  - `field :linked_repo_id`, sem `belongs_to`.
- O link colado na tela (`source_url`) vira origem por `TaskSources.parse_link/1`, com a mesma mensagem de erro de hoje. Uma tarefa que já tem origem (da fonte ou da proposta) a mantém.
- `create_task/4` recebe `origin:`. Com `proposal:`, a origem vem de `Origin.from_input/1`.
- `create_from_linked_issue/4` virou `create_from_item/3` (mesmo título e mesmo prompt `"corpo\n\nIssue: url"`), e `active_for_issue?/2` virou `active_for_source?/3`.
- O sinal `"tasks:linked"`/`{:linked_task_updated, id}` virou `"tasks:sourced"`/`{:source_task_updated, task}`, publicado quando a tarefa tem `source`.
- A nota da decisão vai para `pending_source_note`. A entrega do runner faz merge de `TaskSources.runner_delivery/1`, e o PR usa `TaskSources.pr_reference/1`.
- Quem cuida do PR decide `Integrations.pull_request_keeper/1` (novo): `:platform`, `:runner_with_status` ou `:runner`. Assim o motor não decide nada pelo `linked_repo_id`.

**Propostas**:
- `triage_linked_issue/4` virou `triage_item/3`. O input guarda `"origin"`, e a trava continua com a chave `"triage:" <> url`.
- `triaging?/3` casa a origem nova ou o `issue_url` antigo.
- `origin_url/1` (novo) dá o link para a tela.
- `job_finished/1` chama `TaskSources.triage_finished/1`.
- `TaskKind`: o campo da tela é `source_url`, que vira `origin` no input; `task_params` leva `source_url`.

**Integrações**:
- `Ingest`: o passo 8 usa `TaskSources.active?/3`; o passo 11, `TaskSources.start/3` com `IssueSource.item/2`.
- `Conversation`: usa `TaskSources.Commands` e `apply_command/3`, e acha a tarefa por `linked_repo_id` + `source_ref->>'number'`.
- `Feedback`: lê o número em `source_ref` e a origem da triagem por `Origin.from_input/1`.
- `FeedbackWorker` e `Integrations.Commands` saíram.

**Migração** `priv/repo/migrations/20261124100000_add_task_source.exs`:
- adiciona as colunas novas e o índice `(workspace_id, source, source_id)`;
- `backfill_sql/0` (duas instruções idempotentes) preenche a origem `git_issue` a partir de `issue_url`/`issue_number` e copia `pending_issue_comment`;
- as colunas antigas ficam, sem mapeamento no schema.

### `apps/pipe_maestro_web`

Sem mudança visível: mesmos rótulos, mesmo markup, mesmos `data-testid`.

- `task_live/node_panel.ex` lê `@task.source_url`.
- `proposal_live/show.ex` lê `Proposals.origin_url(@input)`, que funciona para propostas novas e antigas.
- `task_live/index.ex` e `proposal_request.ex`: o campo do formulário passou a ser `:source_url`.
- `IntegrationWebhookController` entra por `TaskSources.receive_webhook("git_issue", key, ...)`, com as mesmas respostas HTTP.

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`

Não mudam. A entrega da etapa tem as mesmas chaves (`"issue_comment"` com `"url"`/`"body"`).

## Testes da etapa 2 corrigidos (e por quê)

Dois ajustes em `task_sources_test.exs`. Nenhum enfraquece o que se prova:

1. **Setup do runner**: o runner do teste não tinha a capacidade `scratch`, que a triagem exige, e a criação da proposta falhava com "atualize este runner para gerar propostas". O setup passou a fazer `record_hello` com `scratch` e o diretório `app`, como no `ingest_test.exs`.
2. **A nota da decisão**: o teste esperava `pending_source_note` preenchida na tarefa devolvida. Mas o motor entrega a nota com o job da próxima etapa e a limpa ao começar a etapa, o mesmo comportamento de hoje com `pending_issue_comment`. A `FakeSource.runner_delivery/1` agora devolve `%{"fake_note" => nota}`, e o teste confere que a nota chegou à entrega do job da próxima etapa e que depois não fica pendente. Isso prova também que a entrega do runner passa pela fonte.

## Testes existentes ajustados (só nomes)

Dois tipos de ajuste:
- **Renomeações**: `issue_url` → `source_url` nos params e nos asserts; `issue: %{linked_repo_id, issue_number}` → `origin: %Origin{...}`; `create_from_linked_issue` → `create_from_item` com `IssueSource.item/2`; `triage_linked_issue` → `triage_item`; `triaging?/2` → `triaging?/3`; o input da triagem conferido por `"origin"`; `issue_number` → `source_ref["number"]`; `Integrations.Commands` → `TaskSources.Commands` (arquivo movido).
- **Testes novos**: um teste de proposta salva no formato antigo, em `proposals_test.exs`, e testes de webhook, polling e resposta em `issue_source_test.exs`, para cobertura.

Arquivos: `tasks_test`, `task_from_project_test`, `proposals_test`, `project_kind_test`, `integrations/{ingest,conversation,feedback,auto_merge,github}_test`, `task_sources/commands_test` e, no web, `runner_channel_test`, `proposal_live_test` e `pull_requests_live_test`.

## Como verificar

```
mix test apps/pipe_maestro/test/pipe_maestro/task_sources_test.exs \
         apps/pipe_maestro/test/pipe_maestro/task_sources \
         apps/pipe_maestro/test/pipe_maestro/integrations/issue_source_test.exs
cd apps/pipe_maestro && mix test          # 625+ testes, 0 falhas
cd apps/pipe_maestro_web && mix test      # 543 testes, 0 falhas
grep -nE "Integrations\.(LinkedRepo|Trigger|IssueState|IssueUrl)|LinkedRepo|Trigger|IssueState|html_url|issue\[" \
  apps/pipe_maestro/lib/pipe_maestro/tasks.ex apps/pipe_maestro/lib/pipe_maestro/tasks/*.ex   # vazio
```

`make ci.quick` (`tmp/ciq.log`):
- compile sem warnings, format, `deps.unlock` e `credo --strict` passaram;
- testes e cobertura passaram em `protocol` (113), `pipe_maestro` (625; total 93,4%) e `web` (543);
- na primeira tentativa, o runner teve 1 falha intermitente, corrigida na seção seguinte.

O Dialyzer está registrado no fim deste arquivo.

## Testes instáveis corrigidos (segunda tentativa)

A primeira tentativa não passou no gate `make test.cover`. Duas falhas intermitentes,
nenhuma causada pela mudança da tarefa, foram corrigidas onde falham:

1. **`PipeMaestroRunner.GatesTest` "a change to the tree runs it again, committed or not"**
   (commit `2b56fd2`).
   - **A primeira hipótese estava errada.** Colisão do arquivo temporário entre VMs: o teste
     continuou falhando, cerca de 3 vezes em 16, rodando sozinho.
   - **Causa real.** `GateCache.tree/3` copiava o índice com `File.cp`, e a cópia ganhava um
     mtime novo. O git compara mtime em segundos. Ele só hasheia de novo uma entrada "racily
     clean", com mtime >= o do índice. Com a cópia mais nova, um arquivo regravado no mesmo
     segundo e com o mesmo tamanho (`"v1"` → `"v2"`) parecia inalterado. A árvore saía com o
     conteúdo velho, e o gate não era achado no cache depois do commit.
   - **Correção.** `copy_index/2` mantém o mtime do índice na cópia (`File.touch/2`). O nome
     também passa a levar `System.pid()`, porque VMs diferentes compartilham o `TMPDIR`.
   - **Teste novo, determinístico.** "a file rewritten with the same size in the second the
     index was written is a change" põe o índice e o arquivo no mesmo segundo do passado.
     Ele falha 3 de 3 sem a correção e passa com ela. O arquivo do teste passou 25 de 25
     rodadas.
   - **Efeito colateral.** A mudança em `apps/pipe_maestro_runner` sobe a versão do runner
     (ADR 0035), e os runners se atualizam uma vez. O bug também existe em produção: ele
     faria um gate passar por cache sobre código que mudou. Por isso a correção vale a
     atualização.
2. **`PipeMaestro.Integrations.CredentialsTest` "two refreshes at once spend the refresh
   token once"** (`config/test.exs`).
   - **Causa.** As duas tasks do teste dividem a única conexão do sandbox. A primeira a
     segura numa transação com `FOR UPDATE` enquanto chama o FakeForgejo. Com a máquina
     carregada por outras suítes, a segunda esperava mais que a fila padrão do DBConnection
     (`could not checkout ... dropped from queue after 420ms`).
   - **Correção.** O Repo de teste ganhou `queue_target: 2_000` e `queue_interval: 5_000`.

Depois disso, `make ci.quick` saiu **0** (`tmp/ciq.log`): `protocol` 113, `pipe_maestro`
628, `web` 543 e runner 285 testes passaram, todos acima do limite de cobertura. Isso
também vale como `test.cover` para esta árvore.

## Pendências para as próximas etapas

- **Documentação** (critério 1): ADR `0053-fontes-de-tarefa.md`, `docs/specs/integracoes.md`, `docs/specs/maquina-de-estados-tarefa.md` e o cabeçalho do ADR 0036, como na seção 8 do plano.
- **e2e**: `e2e/tests/integrations-*.spec.ts` e os `task-*.spec.ts`. Nenhuma tela mudou visualmente, mas o nome do campo dos formulários passou a ser `source_url`; os specs selecionam por `data-testid`, que não mudou.

## Dialyzer

`mix dialyzer`: `Total errors: 0` (passed successfully).
