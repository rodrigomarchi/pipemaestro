# Etapa 1 — Entendimento e plano

**Tarefa:** separar a fonte da tarefa do host git: um behaviour de fonte, com as issues do
Forgejo e do GitHub como primeira implementação.

Base: `origin/main` em `225fdfd` (fast-forward, sem commits alheios na branch).

## 1. Entendimento

Hoje "de onde vem a tarefa" e "onde fica o código" são uma coisa só, dentro de
`PipeMaestro.Integrations` ([ADR 0036](../../docs/adr/0036-integracoes-com-hosts-git.md)), e o
motor de tarefas conhece essa integração:

- `tasks/task.ex` tem `issue_url`, `issue_number`, `belongs_to :linked_repo, LinkedRepo`,
  `issue_feedback`, `pending_issue_comment` e valida o link com `Integrations.IssueUrl`;
- `tasks.ex` faz alias de `Integrations.{LinkedRepo, Trigger}`, tem
  `create_from_linked_issue/4` (lê `issue["title"]`, `["body"]`, `["html_url"]`, `["number"]`),
  `issue_link/1` (lê `linked_repo_id`/`issue_number` do input da proposta),
  `active_for_issue?/2`, publica `"tasks:linked"` só com `linked_repo_id`, escreve o
  `pending_issue_comment` (`issue_comment/5`), põe `"issue_comment"` na entrega do runner
  (`runner_delivery/2`) e `Closes <issue_url>` no PR (`pr_body/2`);
- `proposals.ex` tem `triage_linked_issue/4` (recebe `LinkedRepo` e `Trigger`), `triaging?/2`
  por `input->>'issue_url'` e chama `Integrations.Feedback.triage_finished/1`;
  `proposals/task_kind.ex` tem `issue_url`, `linked_repo_id` e `issue_number` no input.

**Para quem usa, nada muda.** Telas, comentários e labels no host, commit status, PRs,
comandos, reconciliação e auto-merge continuam iguais. O que muda é interno: uma camada
`PipeMaestro.TaskSources` com um behaviour, um modelo normalizado do item e uma origem
genérica na tarefa. Uma fonte nova (Jira, Linear, ClickUp) entra sem tocar no motor.

### Critérios de aceite, verificáveis

| # | Critério | Como verificar |
|---|---|---|
| 1 | ADR `0053-fontes-de-tarefa.md` com behaviour, modelo normalizado, fonte × host git e fonte → projeto; `integracoes.md` atualizado | leitura; ADR 0036 aponta para o 0053 |
| 2 | Behaviour com `@callback` e `@moduledoc`; as issues do Forgejo e do GitHub o implementam | `@behaviour PipeMaestro.TaskSources.Source` + `@impl` em `PipeMaestro.Integrations.IssueSource` |
| 3 | Motor sem a integração | `grep -nE "Integrations\.(LinkedRepo\|Trigger\|IssueState\|IssueUrl)\|LinkedRepo\|Trigger\|IssueState\|html_url\|issue\[" apps/pipe_maestro/lib/pipe_maestro/tasks.ex apps/pipe_maestro/lib/pipe_maestro/tasks/*.ex` vazio |
| 4 | Fonte fictícia, só no teste, cria, reflete e comanda uma tarefa sem mudar o motor | `test/pipe_maestro/task_sources_test.exs` |
| 5 | Migração preenche a origem; teste com tarefa de issue vinculada e com só `issue_url` | `test/pipe_maestro/task_sources/origin_backfill_test.exs` |
| 6 | Nenhuma mudança visível | testes atuais de integrações, tarefas e propostas passam, ajustados só em nome de campo ou função; `e2e/tests/integrations-*.spec.ts` passam |
| 7 | `make ci` verde; `make e2e` dos specs de integrações e de tarefa | gate |

## 2. Desenho

### 2.1 O contexto `PipeMaestro.TaskSources` (domínio, sem web)

Arquivos novos em `apps/pipe_maestro/lib/pipe_maestro/`:

- **`task_sources.ex`**: o contexto e o registro de fontes.
  - Registro por chave `source` em configuração:
    `config :pipe_maestro, PipeMaestro.TaskSources, sources: %{"git_issue" => PipeMaestro.Integrations.IssueSource}`
    (`config/config.exs`). `fetch(source)` e `sources/0` leem o `Application.get_env` em
    tempo de execução, então um teste registra uma fonte com `Application.put_env`.
  - Funções genéricas que despacham para a fonte certa, todas sem efeito quando a tarefa
    não tem fonte ou a fonte não está registrada:
    `start/4` (item → tarefa ou triagem), `active?/3` (tarefa ou triagem em andamento para
    `source` + `external_id`), `parse_link/1`, `runner_delivery/1`, `pr_reference/1`,
    `triage_finished/1`, `apply_command/3`, `task_for/3`.
- **`task_sources/source.ex`**: o behaviour (seção 2.2).
- **`task_sources/item.ex`**: a struct normalizada do item lido na fonte:
  `source`, `external_id`, `url`, `title`, `description`, `author`, `labels`, `priority`
  (`nil` quando a fonte não tem), `kind` (o rótulo do item na fonte, `"Issue"`), `ref`
  (mapa da fonte, opaco ao motor) e `linked_repo_id` (seção 2.4). `Item.origin/1`.
- **`task_sources/origin.ex`**: a origem que a tarefa e a proposta guardam:
  `source`, `external_id`, `url`, `ref`, `linked_repo_id`. Converte de e para o mapa do
  input da proposta (`to_input/1`, `from_input/1`), lendo também o formato antigo
  (`issue_url`, `linked_repo_id`, `issue_number`) das propostas já existentes.
- **`task_sources/commands.ex`**: o que hoje é `Integrations.Commands` (parse, `help/1`,
  `word/1`, `answers/2`), movido sem mudar o texto: os comandos `seguir`, `refazer`,
  `responder`, `pausar`, `cancelar`, `corrigir` valem para qualquer fonte.
  `TaskSources.apply_command(task, command, via: ...)` leva cada comando à mesma função da
  tela (`Tasks.advance/3`, `retry_stage/3`, `answer/4`, `request_pause/1`, `cancel_task/2`,
  `correct/3`), em nome do dono da tarefa, e devolve `{:ok, task}` ou `{:error, motivo}`
  com o texto de hoje (o `run/3`, `owner/1` e `reason/1` que hoje estão em
  `Integrations.Conversation`).
- **`task_sources/dispatcher.ex`**: GenServer que assina `Tasks.subscribe(:sourced)` e,
  para cada mudança de uma tarefa com fonte, chama `task_changed/1` da fonte dela. Entra
  no lugar de `Integrations.FeedbackWorker` em `application.ex` (desligado nos testes como
  hoje, `config/test.exs`).

O `IssueUrl` sai de `tasks/task.ex`: o link colado à mão passa por `TaskSources.parse_link/1`,
que pergunta a cada fonte registrada; a de issues reconhece `IssueUrl.regex/0` e devolve a
mesma mensagem de erro de hoje.

### 2.2 O behaviour `PipeMaestro.TaskSources.Source`

As assinaturas são o ponto de partida; a implementação pode afinar tipos, não as
responsabilidades.

```elixir
# 1. Receber o gatilho (uma fonte tem ao menos um dos dois)
@callback receive_webhook(key :: String.t() | nil, headers :: map(), raw_body :: binary(), keyword()) ::
            {:ok, term()} | :duplicate | {:error, atom()}
@callback poll(now :: DateTime.t(), keyword()) :: map()

# 2. Ler e normalizar o item
@callback fetch_item(Origin.t()) :: {:ok, Item.t()} | {:error, term()}
@callback parse_link(url :: String.t()) :: {:ok, Origin.t()} | {:error, String.t()}

# 3. Refletir o andamento
@callback task_changed(Task.t()) :: :ok
@callback triage_finished(Job.t()) :: :ok
@callback runner_delivery(Task.t()) :: map()
@callback pr_reference(Task.t()) :: String.t() | nil

# 4. Respostas e comandos
@callback reply(Origin.t(), reply_to :: term(), text :: String.t()) :: :ok | {:error, term()}

@optional_callbacks receive_webhook: 4, poll: 2, parse_link: 1
```

- `runner_delivery/1`: o que o runner faz pela fonte junto da entrega de uma etapa. A de
  issues devolve `%{"issue_comment" => %{"url", "body"}}` quando há
  `pending_source_note` (o mesmo campo do protocolo de hoje); o motor só faz o merge.
- `pr_reference/1`: a linha da origem no PR. A de issues devolve `"Closes <url>"`.
- `reply/3`: como a fonte responde a uma pessoa (comando desconhecido, comando que não vale
  agora). Os comandos em si chegam pelo gatilho, e a fonte os aplica com
  `TaskSources.apply_command/3`.

### 2.3 A implementação de issues: `PipeMaestro.Integrations.IssueSource`

Um módulo, chave `"git_issue"`, para Forgejo e GitHub (o `Provider` já separa os dois).
Passa por trás da interface sem reescrever:

| Callback | Reaproveita |
|---|---|
| `receive_webhook/4` | `Ingest.receive_webhook/4` (com `key` = id da conexão) e `Ingest.receive_app_webhook/3` (`key` `nil`, o App do GitHub) |
| `poll/2` | `Reconciler.run/2` (o processo do `Reconciler` continua sendo o relógio da fonte) |
| `fetch_item/1` | `provider.get_issue/3` do `Ingest.fresh_issue/4`, normalizado em `Item` |
| `parse_link/1` | `IssueUrl.regex/0` e `IssueUrl.message/0` |
| `task_changed/1` | o corpo de `FeedbackWorker.handle_info/2`: `Feedback.sync/1` + `AutoMerge.check/1` em `Integrations.background/1`, `Feedback.mark_dirty/1` se ocupado; nada sem `linked_repo_id` |
| `triage_finished/1` | `Feedback.triage_finished/1` |
| `runner_delivery/1`, `pr_reference/1` | os trechos que hoje estão em `Tasks.runner_delivery/2` e `pr_body/2` |
| `reply/3` | `client.provider.create_comment/4` |

Mudanças em volta:

- `Ingest.start/5` monta o `Item` a partir da issue lida e chama
  `TaskSources.start(workspace, item, target)`, com
  `target = %{mode, project_id: repo.project_id, pipeline_id, acting_user_id, auto_approve}`.
  O resto dos passos 1 a 11 não muda. `not_active/2` usa `TaskSources.active?/3`.
- `Conversation` usa `TaskSources.Commands` e `TaskSources.apply_command/3`. Acha a tarefa
  pela origem: `linked_repo_id` + o número em `source_ref`, como hoje com `issue_number`.
  A 👍, o audit `task.decided_from_host` e as respostas continuam iguais.
- `Feedback`, `AutoMerge` e `Conversation` leem o número da issue em
  `task.source_ref["number"]` em vez de `task.issue_number`.
  `Feedback.dirty_task_ids/0` não muda (`linked_repo_id`).
- `Integrations.FeedbackWorker` sai; o `Dispatcher` + `IssueSource.task_changed/1` fazem o
  mesmo. As referências em `auto_merge_worker.ex` e nos moduledocs passam a apontar para eles.
- `Integrations.Commands` sai (vira `TaskSources.Commands`).

### 2.4 Fonte × host git: o `linked_repo_id`

O `linked_repo_id` da tarefa tem dois papéis hoje: é a issue de origem (com
`issue_number`) e é o repositório do host onde a plataforma cuida do PR, do commit status,
da credencial git (`Integrations.git_credential_for_job/1`) e do auto-merge
(`Integrations.keeps_pull_request?/1`). O plano separa os papéis sem mudar comportamento:

- **origem**: `source`, `source_id`, `source_url`, `source_ref` (o número da issue fica em
  `source_ref`);
- **host git**: `linked_repo_id` continua coluna (FK, usada em joins), mas o schema da
  tarefa a declara como `field :linked_repo_id, :binary_id`, sem `belongs_to` (nenhum
  código faz preload de `:linked_repo`; é o mesmo padrão de `project_id`). Quem a preenche
  é a fonte, pela `Origin`. O motor só a guarda e pergunta a `Integrations` se ela cuida do
  PR: o `delivery/2` de `tasks.ex` perde o guard `is_binary(task.linked_repo_id)` e chama só
  `Integrations.keeps_pull_request?/1`, que já trata `nil`.

Ligar o host git ao projeto (e não à origem) mudaria o comportamento de tarefas criadas à
mão num projeto com repositório vinculado; fica fora desta tarefa e registrado no ADR.

### 2.5 O motor (`tasks.ex`, `tasks/*.ex`)

- `tasks/task.ex`: sai `alias Integrations.{IssueUrl, LinkedRepo}`; saem do schema
  `issue_url`, `issue_number`, `pending_issue_comment` e `belongs_to :linked_repo`; entram
  `source`, `source_id`, `source_url`, `source_ref` (`:map`, default `%{}`),
  `pending_source_note` e `field :linked_repo_id, :binary_id`. `issue_feedback` continua no
  schema, mas o motor não lê nem escreve (seção 2.6). `create_changeset/2` aceita
  `source_url` (o link colado na tela) e chama `TaskSources.parse_link/1`: com link válido,
  põe `source`, `source_id`, `source_url`, `source_ref`; senão, erro em `:source_url` com a
  mensagem de hoje.
- `tasks.ex`:
  - sai `alias Integrations.{LinkedRepo, Trigger}` (fica `alias PipeMaestro.Integrations`,
    para `keeps_pull_request?/1` e `public_url/0`, que são do host git);
  - `create_task/4` recebe `origin: %Origin{}` no lugar de `issue: %{linked_repo_id, issue_number}`;
    com `proposal:`, a origem vem de `Origin.from_input/1` do input da proposta
    (`issue_link/1` sai);
  - `create_from_linked_issue/4` vira `create_from_item(workspace, %Item{}, target)`:
    título `String.slice(item.title || item.kind, 0, 120)`, prompt
    `"#{description || title}\n\n#{item.kind}: #{item.url}"` (o mesmo texto de hoje para
    issues), `pipeline_id` e `project_id` do alvo, em nome de `acting_user_id`;
  - `active_for_issue?/2` vira `active_for_source?(workspace, source, external_id)`;
  - `notify/1` publica em `"tasks:sourced"` a mensagem `{:source_task_updated, task}` quando
    `task.source` existe (`subscribe(:sourced)` no lugar de `subscribe(:linked)`);
  - `issue_comment/5` vira `source_note/5` e escreve `pending_source_note` (o texto da
    decisão não muda) quando `task.source_url` existe;
  - `runner_delivery/2` faz merge de `TaskSources.runner_delivery(task)`; `pr_body/2` usa
    `TaskSources.pr_reference(task)` para a linha `Closes ...`.

### 2.6 `issue_feedback` e `pending_issue_comment`

- **`pending_issue_comment` → `pending_source_note`**: o motor escreve o resumo da decisão
  (texto genérico); a fonte decide como levá-lo. A de issues o entrega pelo runner (modo
  `"runner"`), como hoje.
- **`issue_feedback` fica com esse nome e é de `Integrations`**: é o estado do retorno no
  host git. Para as issues, a sincronização escreve numa passada a label, o comentário de
  status e as notificações (estado da fonte), e também o commit status, o `pr_number`, o
  `merged` e o `conflict_sha` (estado do host, lido por `AutoMerge`). Separar isso em
  `source_state` e estado do PR seria reescrever `Feedback.sync/1`, o que esta tarefa não
  faz. O ADR registra isso e o motor não toca o campo. A tela continua lendo
  `issue_feedback["error"]`.

### 2.7 Propostas

- `proposals.ex`: `triage_linked_issue/4` vira `triage_item(workspace, %Item{}, target)`.
  Guarda `"origin" => Origin.to_input(origin)` no input, e não mais `issue_url`,
  `linked_repo_id` e `issue_number`. A trava (`pg_advisory_xact_lock`) continua com a chave
  `"triage:" <> external_id`. Para issues, `external_id` é a URL, então a chave é a mesma
  de hoje e a trava continua por issue, inclusive durante o deploy. O pedido continua
  `"# título\n\ncorpo cortado"`. O audit `proposal.requested` mantém a chave `"issue_url"`
  (`source_url`), para não mudar o que o registro de auditoria mostra.
- `triaging?/2` vira `triaging?(workspace, source, external_id)`. A consulta casa
  `input->'origin'->>'source'/'external_id'` **ou** o `input->>'issue_url'` antigo, para
  triagens que estejam rodando no deploy.
- `job_finished/1` chama `TaskSources.triage_finished/1`, que acha a fonte por
  `Origin.from_input/1`.
- `proposals/task_kind.ex`: os `@types` trocam `issue_url`, `linked_repo_id` e
  `issue_number` por `source_url` (o campo da tela) e `origin` (`:map`). O `changeset` valida
  o `source_url` com `TaskSources.parse_link/1` e põe o `origin`. `task_params` leva
  `origin` (via `Origin.from_input/1`, que também lê o formato antigo). O texto
  "A ideia vem da issue …" do prompt da triagem não muda.

## 3. Mudanças por app

### `apps/pipe_maestro` (muda)

- Novo contexto `task_sources.ex` + `task_sources/{source,item,origin,commands,dispatcher}.ex`.
- `integrations/issue_source.ex` novo; `ingest.ex`, `conversation.ex`, `feedback.ex`,
  `auto_merge.ex`, `reconciler.ex` (só moduledoc), `auto_merge_worker.ex` (moduledoc)
  ajustados; `feedback_worker.ex` e `commands.ex` saem.
- `tasks.ex`, `tasks/task.ex`, `proposals.ex`, `proposals/task_kind.ex` (seções 2.5 e 2.7).
- `application.ex`: `worker(PipeMaestro.TaskSources.Dispatcher)` no lugar do
  `FeedbackWorker`; `config/test.exs` e `config/config.exs` (registro de fontes).
- **Migração** `priv/repo/migrations/20261124100000_add_task_source.exs`:
  - `alter table(:tasks)`: `source :text`, `source_id :text`, `source_url :text`,
    `source_ref :map, default: %{}, null: false`, `pending_source_note :text`;
    `create index(:tasks, [:workspace_id, :source, :source_id])`;
  - `backfill_sql/0` público (como `AddRunnerToProjects.backfill_projects_sql/0`, testado
    em `runner_backfill_test.exs`):

    ```sql
    UPDATE tasks SET source = 'git_issue', source_id = issue_url, source_url = issue_url,
      source_ref = CASE WHEN issue_number IS NULL THEN '{}'::jsonb
                        ELSE jsonb_build_object('number', issue_number) END
    WHERE issue_url IS NOT NULL AND source IS NULL;
    UPDATE tasks SET pending_source_note = pending_issue_comment
    WHERE pending_issue_comment IS NOT NULL AND pending_source_note IS NULL;
    ```

    Uma tarefa com só `issue_url` (criada à mão) ganha origem `git_issue` sem `number` e
    sem `linked_repo_id`, como hoje. Hoje não existe tarefa com `linked_repo_id` sem
    `issue_url`: os dois caminhos que preenchem um preenchem o outro
    (`create_from_linked_issue/4` e a triagem). O teste da migração confirma isso;
  - **as colunas antigas ficam** (`issue_url`, `issue_number`, `pending_issue_comment`),
    sem mapeamento no schema. O deploy roda `Release.migrate` antes de subir a versão nova
    (`docs/guias/deploy.md`), então a versão velha ainda lê `tasks` com essas colunas
    durante a troca. Remover as colunas fica para uma migração posterior, registrada no
    ADR. `down` remove as colunas novas e o índice; as antigas guardam os dados.

### `apps/pipe_maestro_web` (muda, sem mudança visível)

- `live/task_live/node_panel.ex`: `@task.source_url` no lugar de `@task.issue_url` (mesmo
  `IntegrationComponents.issue_label/1`, mesmo markup e `data-testid`).
- `live/proposal_live/show.ex`: o link vem de `Origin.from_input(@input).url` (propostas
  novas e antigas).
- `live/task_live/index.ex` e `proposal_request.ex`: o campo do formulário passa a ser
  `:source_url`. O rótulo, o placeholder, o texto de ajuda e o `data-testid="task-issue-url"`
  não mudam.
- `controllers/integration_webhook_controller.ex`: passa a chamar
  `TaskSources.receive_webhook("git_issue", key, headers, body)`. As respostas HTTP não
  mudam. `integration_live/{repo,show}.ex` continuam chamando `Reconciler.sync_repo/3` e
  `Ingest.replay/3` (ações de tela da integração de host git, não do behaviour).
- Nenhum Channel muda.

### `apps/pipe_maestro_protocol` (não muda)

### `apps/pipe_maestro_runner` (não muda)

## 4. Fronteiras

- `TaskSources` fica no domínio (`apps/pipe_maestro`), sem Phoenix além do `PubSub`, que o
  domínio já usa. O web continua dependendo só do domínio e do `protocol`.
- O runner e o `protocol` não ganham dependência nem mudam.
- Dentro do domínio, a direção fica: `Tasks`/`Proposals` → `TaskSources` (genérico) ←
  `Integrations.IssueSource`. `TaskSources` chama `Tasks` e `Proposals` para criar,
  triar e comandar. É um ciclo de chamadas em tempo de execução entre contextos, que já
  existe hoje (`Tasks` ↔ `Integrations`). Não há dependência de compilação em ciclo: o
  motor usa as structs `Item`/`Origin`, que não dependem de `Tasks`.

## 5. Protocolo

**Não toca `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels.** A
entrega da etapa continua com as mesmas chaves (`"push"`, `"pr"`, `"status"`,
`"issue_comment"` com `"url"`/`"body"`). Só muda quem calcula o `"issue_comment"`: a fonte,
via `runner_delivery/1`. `docs/specs/protocolo-runner.md` não muda, a versão do protocolo
não sobe, e runners antigos continuam compatíveis sem nenhum tratamento.

## 6. Telas

Nenhuma mudança visual. Não entram `data-testid` novos nem specs Playwright novos. Os specs
que provam "nenhuma mudança visível": `e2e/tests/integrations-*.spec.ts` (auto-merge,
conversation, github, issue-to-task, setup) e `task-pipeline.spec.ts`,
`task-stage-panel.spec.ts`, `task-files.spec.ts`. Não precisa de screenshots
(`e2e.shots`), porque nada muda na aparência.

## 7. Testes

| Critério | Teste |
|---|---|
| 2, 4 | **`test/pipe_maestro/task_sources_test.exs`** (`async: false`): define `FakeSource` no próprio arquivo (`@behaviour` + `@impl`, sem webhook nem polling), registra com `Application.put_env` e restaura no `on_exit`. **Cria**: `TaskSources.start/4` com um `Item` `source: "fake"` → tarefa com `source`/`source_id`/`source_url`; `active?/3` verdadeiro. **Reflete**: com `start_supervised(Dispatcher)`, uma mudança da tarefa chega ao `task_changed/1` da fonte (mensagem ao pid do teste); `pr_block/1` traz o `pr_reference/1` da fonte; a entrega do job traz o `runner_delivery/1`. **Comanda**: com a tarefa em `awaiting_decision`, `TaskSources.apply_command/3` com `seguir` avança e com `cancelar` cancela; um comando que não vale agora devolve o motivo de hoje. Além disso, a mesma tarefa vista pela tela fica igual a uma tarefa sem fonte. |
| 2 | `test/pipe_maestro/integrations/issue_source_test.exs`: `parse_link/1` (link válido e inválido, a mensagem), `fetch_item/1` normaliza uma issue (stub do provider que os testes de integrações já usam), `pr_reference/1`, `runner_delivery/1` com e sem nota. |
| 3 | `grep` da tabela da seção 1, rodado na revisão. |
| 5 | **`test/pipe_maestro/task_sources/origin_backfill_test.exs`**, no padrão de `runner_backfill_test.exs`: grava `issue_url`/`issue_number`/`linked_repo_id`/`pending_issue_comment` por SQL numa tarefa de issue vinculada e numa só com `issue_url`, roda `backfill_sql/0` e confere `source`, `source_id`, `source_url`, `source_ref`, `pending_source_note` e `linked_repo_id` intacto. Uma tarefa sem issue fica sem origem. Rodar duas vezes não muda nada. |
| 6 | Os testes atuais passam com renomeações mecânicas: `issue_url:` → `source_url:` nos params e nos asserts de tarefa; `issue_number` → `source_ref["number"]`; `create_from_linked_issue` → `create_from_item`; `triage_linked_issue` → `triage_item`; `subscribe(:linked)` → `subscribe(:sourced)`; `pending_issue_comment` → `pending_source_note`; `Integrations.Commands` → `TaskSources.Commands`. Arquivos: `tasks_test.exs`, `tasks/task_from_project_test.exs`, `proposals_test.exs`, `integrations/{ingest,conversation,feedback,reconciler,auto_merge,github,schemas}_test.exs`, e no web `proposal_live_test.exs`, `pull_requests_live_test.exs`, `runner_channel_test.exs`. Um teste de proposta com input no formato antigo (`issue_url`/`linked_repo_id`/`issue_number`) confere a compatibilidade (`Origin.from_input/1`, `triaging?/3`, criação da tarefa a partir dela). |
| 7 | `make ci`; `make e2e FILE=...` para os specs da seção 6. |

## 8. Documentação

- **ADR novo `docs/adr/0053-fontes-de-tarefa.md`**:
  - o behaviour e suas quatro responsabilidades;
  - o `Item` e a `Origin`;
  - o registro por chave `source` (configuração);
  - a regra "uma fonte com polling traz seu processo para `application.ex`";
  - fonte ≠ host git (push, PR, commit status, credencial e auto-merge ficam em
    `Integrations`, decididos por `keeps_pull_request?/1` sobre o `linked_repo_id`);
  - fonte → projeto: o gatilho de uma fonte sem código diz o projeto, e o projeto escolhe
    runner e pasta (ADR 0034); nas issues, o projeto vem do `LinkedRepo`;
  - o destino de `issue_feedback` (fica, é de `Integrations`) e de `pending_issue_comment`
    (vira `pending_source_note`);
  - as colunas antigas mantidas até uma migração posterior;
  - o que fica fora do behaviour: as telas de configurar fontes, o vínculo host git ↔
    projeto e a divisão de `issue_feedback`.
- `docs/specs/integracoes.md`: seção nova sobre a fonte `git_issue` (o que cada callback
  faz); a tabela do modelo (§1) e a linha da tarefa (`linked_repo_id`, `source*`,
  `issue_feedback`); §4 passo 11 (`TaskSources.start/4`); §5 (`Dispatcher` +
  `task_changed/1`); §6 (`TaskSources.Commands`).
- `docs/specs/maquina-de-estados-tarefa.md`: uma linha "Origem numa fonte" ao lado de
  "Origem numa proposta" (a tarefa guarda `source`/`source_id`/`source_url`; o sinal
  `tasks:sourced`).
- `docs/adr/0036-integracoes-com-hosts-git.md`: linha "Relacionado: ADR 0053" no
  cabeçalho, e qualquer índice de ADRs que exista ganha a linha nova.
- Sem contagens na prosa.

## 9. Riscos

- **Dados existentes**: o backfill é idempotente (`WHERE source IS NULL`) e as colunas
  antigas ficam, então não há perda nem janela quebrada no deploy. Tarefas criadas depois
  do deploy não preenchem as colunas antigas: um rollback de código as veria sem
  `issue_url`. Isso fica registrado no ADR.
- **Propostas em andamento no deploy**: o input no formato antigo é lido por
  `Origin.from_input/1` e pelo `OR` em `triaging?`. Há teste para isso.
- **Concorrência**: a trava da triagem mantém a chave `"triage:" <> external_id`, igual à
  de hoje para issues. Entregas processadas pela versão velha e pela nova durante o deploy
  se travam entre si, e o `active?`/`triaging?` e o `IssueState.fired` continuam impedindo
  o duplo disparo.
- **`Conversation` sem `issue_number` em coluna**: a busca passa a ser
  `linked_repo_id = ? AND (source_ref->>'number')::int = ?`. O índice existente começa por
  `linked_repo_id`, o que basta para o volume por repositório.
- **Sinal mais largo**: tarefas criadas à mão com link passam a publicar em
  `tasks:sourced`. `IssueSource.task_changed/1` sai cedo sem `linked_repo_id`, o mesmo
  efeito de hoje.
- **Dialyzer**: callbacks opcionais e structs novas pedem `@type t` e `@spec` completos. O
  `field :linked_repo_id` no lugar de `belongs_to` muda o `@type` da tarefa (sai
  `linked_repo`).
- **Cobertura**: os módulos novos são cobertos pelos testes da seção 7. O `Dispatcher`, que
  fica desligado na config de teste, é exercitado com `start_supervised`.
- **Credo**: aliases desde a primeira escrita; `TaskSources` não pode virar um módulo
  grande demais (o despacho fica em funções curtas).

## 10. Ordem sugerida de implementação

1. `TaskSources` (behaviour, `Item`, `Origin`, `Commands`, registro, `Dispatcher`) + migração + teste da migração.
2. Motor (`tasks.ex`, `tasks/task.ex`) e propostas sobre a origem genérica.
3. `IssueSource` + ajustes em `Ingest`, `Conversation`, `Feedback`, `AutoMerge`; remoção de `FeedbackWorker` e `Integrations.Commands`.
4. Web (campos e leitura da origem, controller de webhook).
5. Teste da fonte fictícia; ajustes mecânicos dos testes existentes.
6. ADR 0053, specs, ADR 0036.
7. `make ci` e `make e2e` dos specs de integrações e tarefa.
