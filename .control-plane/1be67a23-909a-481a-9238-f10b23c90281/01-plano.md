# Etapa 1 — Entendimento e plano

Tarefa: **Retenção por workspace para anexos (dias e cota) e para o conteúdo dos eventos do agente.**

Base: `origin/main` em `225fdfd` (fast-forward, sem commits alheios na branch).

## Entendimento

Hoje, dois dados do control plane crescem sem que o cliente escolha nada:

- **Anexos** (`PipeMaestro.Jobs.Files`, `PipeMaestro.Jobs.JobFile`, tabela `job_files`, `bytea`): sem prazo nem
  cota; só saem com o job ou a tarefa (ADR 0042, consequência "Ainda não há retenção nem cota").
- **Conteúdo dos eventos** (`PipeMaestro.Jobs.Event`, `job_events`): `PipeMaestro.Maintenance.run/2` apaga
  eventos e `PipeMaestro.Jobs.Telemetry` de **todos** os jobs terminados há mais de `:job_events_days` (30),
  depois de `Insights.store_summary/1`. Não há opção "só metadados" (plano §riscos e questão em aberto 3).

Depois da mudança, o operador escolhe por workspace, no backoffice:

| Campo | Padrão | Significado |
|---|---|---|
| `job_files_retention_days` | `nil` (sem limite) | dias, contados de `inserted_at`, até o anexo perder o conteúdo |
| `job_files_quota_mib` | `nil` (sem cota) | soma máxima de anexos não podados do workspace |
| `agent_events_retention_days` | `30` | dias depois do fim do job com o conteúdo completo dos eventos |
| `agent_events_after_retention` | `"metadata"` | `"metadata"` (fica o esqueleto do evento) ou `"delete"` (como hoje) |

Os padrões preservam o comportamento atual para anexos (nada some) e o prazo de 30 dias para eventos; a
única mudança de padrão é que, passado o prazo, o evento vira só metadados em vez de sumir (resposta à
questão em aberto 3, registrada no ADR novo).

Para quem usa:
- membros veem, na tela de Uso, o uso de anexos contra a cota e as políticas em vigor (somente leitura);
- anexo podado aparece com o nome e "removido pela retenção", sem link; o download responde 410;
- job com eventos podados mostra a linha do tempo (tipo, ferramenta, duração, custo, erro) com um aviso
  único "conteúdo removido pela retenção";
- upload além da cota é recusado com 413 `quota_exceeded`; a tentativa da etapa mostra
  "N arquivos recusados: a cota de anexos do workspace (X MiB) foi atingida"; job e tarefa terminam como
  terminariam.

### Critérios de aceite (verificáveis)

1. `"metadata"`: após `Maintenance.run/2`, todos os eventos do job continuam (mesmos `seq` e `type`), `data`
   só com as chaves de metadados; `jobs.events_pruned_at` preenchido; segunda execução não toca no job.
2. `"delete"`: eventos somem. `Telemetry` some nas duas políticas.
3. Dois workspaces com prazos diferentes, no mesmo `run/2`, são podados cada um pelo seu prazo.
4. `PipeMaestro.Usage` (totais, por dia, por estágio) e a contagem de `Audit.list_events/2` idênticos antes
   e depois da poda; `Insights.job/1` de job podado lê o resumo guardado (não recalcula).
5. Anexo além do prazo: `content` nulo, `pruned_at` preenchido; página da tarefa renderiza
   "removido pela retenção"; download 410.
6. Cota: `PUT` que ultrapassa → 413 `quota_exceeded`; arquivo não gravado; `jobs.files_refused_quota`
   incrementado; aviso específico na tentativa; job/tarefa sem mudança de status; substituição desconta
   o antigo; podados não contam.
7. Backoffice edita e valida os quatro campos; detalhe do workspace mostra uso × cota; Uso mostra o mesmo número.
8. Padrões: nenhum anexo perde conteúdo sem configuração; eventos mantêm 30 dias.
9. ADR 0053, ADR 0042, plano e guia de deploy atualizados.
10. `make ci` e `make e2e` (telas tocadas) verdes.

## Mudanças por app

### `apps/pipe_maestro` (domínio)

**Migração** `priv/repo/migrations/2026112410000x_add_retention_policies.exs` (depois de
`20261123100000_add_session_totals_to_jobs.exs`):

- `workspaces`: `job_files_retention_days :integer null`, `job_files_quota_mib :integer null`,
  `agent_events_retention_days :integer not null default 30`,
  `agent_events_after_retention :string not null default 'metadata'`
  + `check constraint` para os valores (`metadata`/`delete`, faixas positivas).
- `jobs`: `events_pruned_at :utc_datetime null`, `files_refused_quota :integer not null default 0`.
- `job_files`: `pruned_at :utc_datetime null`; `content` passa a aceitar `NULL`
  (`modify :content, :binary, null: true`, se hoje for `not null`).
- Índices: `job_files (workspace_id) where pruned_at is null` (soma de uso e poda);
  `jobs (finished_at) where events_pruned_at is null` (seleção da poda).
- **Backfill** (no `up`): `UPDATE jobs SET events_pruned_at = now()` para jobs terminados há mais de
  30 dias **sem** eventos e sem telemetry — já podados pelo regime antigo. Sem isso, a primeira execução
  reprocessaria todo o histórico (ver Riscos).

**`PipeMaestro.Workspaces.Workspace`** (`workspaces/workspace.ex`): campos novos,
`@type t`, `@moduledoc`, e no `changeset/2`:
- `job_files_retention_days`: `validate_number 1..3650`, "use de 1 a 3650 dias";
- `job_files_quota_mib`: `greater_than: 0` (teto razoável, p.ex. ≤ 1_048_576 = 1 TiB, "use um número positivo");
- `agent_events_retention_days`: obrigatório, `1..3650`;
- `agent_events_after_retention`: `Ecto.Enum` `[:metadata, :delete]` (ou string + `validate_inclusion`)
  com mensagem em português. Recomendo `Ecto.Enum` (`:metadata | :delete` no `@type`), gravado como string.

**`PipeMaestro.Jobs.Event`**: a lista de chaves mantidas num só lugar, nomeada e testada:
`@metadata_keys` + `metadata_keys/0` + `metadata_only(map) :: map` (`Map.take/2`). Chaves:
`name`, `tool_name`, `id`, `tool_use_id`, `parent_tool_use_id`, `duration_ms`, `duration_api_ms`,
`ttft_ms`, `delay_ms`, `usage`, `model_usage`, `cost_usd`, `is_error`, `error`, `status`, `subtype`,
`stop_reason`, `terminal_reason`, mais os numéricos/enumerados sem conteúdo do usuário que a linha do
tempo já mostra: `model`, `num_turns`, `pre_tokens`, `attempt`, `max_retries`. Saem `text`, `input`,
`arguments`, `structured_output`, `todos`, `decision`, `cwd`, `tools`, `mcp_servers`, etc. (allowlist:
tudo que não está na lista sai). As chaves extras ficam documentadas no ADR como decisão.

**`PipeMaestro.Jobs.Job`**: `events_pruned_at`, `files_refused_quota` no schema, `@type`, `@moduledoc`
(não entram no changeset do runner; só o control plane os escreve).

**`PipeMaestro.Jobs.JobFile`**: `pruned_at`, `@type`, `@moduledoc`, `pruned?/1`.

**`PipeMaestro.Jobs.Files`**:
- `store/4`: depois de `lock_job/2` e `within_job_limits/3`, `within_quota/4`: se o workspace tem cota,
  `pg_advisory_xact_lock(hashtext('job_files_quota:' <> workspace_id))` (mesmo padrão de
  `PipeMaestro.Proposals`, linha 291; não trava a linha do workspace, que o backoffice edita), soma
  `byte_size` dos não podados do workspace **exceto** o arquivo deste job no mesmo `path`, e recusa com
  `{:error, :quota_exceeded}` se `uso + size > quota_mib * 1_048_576`. Sem cota, nenhum lock nem soma.
  `store_error` ganha `:quota_exceeded`.
- A recusa é contada **fora** da transação (que sofre rollback): após `Repo.transact/1` devolver
  `{:error, :quota_exceeded}`, `Repo.update_all(from j in Job, where: j.id == ^id, inc: [files_refused_quota: 1])`.
- `insert/3`: o `on_conflict` passa a repor também `pruned_at: nil` (reenviar um caminho podado volta a
  ter conteúdo).
- `workspace_usage(Workspace.t()) :: %{bytes: non_neg_integer(), quota_bytes: pos_integer() | nil}`.
- `prune(DateTime.t(), keyword()) :: non_neg_integer()`: `update_all` com join em `workspaces`, onde
  `pruned_at is null and w.job_files_retention_days is not null and f.inserted_at < now - make_interval(days => w.job_files_retention_days)`
  (como `RunnerTelemetry.prune_logs/1`), `set content: nil, pruned_at: now`, limitado a `:batch` ids por
  subquery.
- `get_for_download/2`: devolve o arquivo podado também (sem conteúdo), para o controller responder 410.
- `@moduledoc` atualizado.

**`PipeMaestro.Maintenance`**:
- Sai `:job_events_days`. Seleção: jobs com `finished_at < now - make_interval(days => w.agent_events_retention_days)`
  e `events_pruned_at is null`, join em `workspaces`, `limit: ^batch`, selecionando a política.
- Para cada job: `Insights.store_summary/1` **só se** ainda tem eventos ou telemetry (um job podado no
  regime antigo, sem nada, guarda o resumo que já tem); apaga `Telemetry`; `"delete"` → `delete_all`
  dos eventos; `"metadata"` → `update_all` em SQL com
  `(SELECT coalesce(jsonb_object_agg(k, v), '{}') FROM jsonb_each(data) AS x(k, v) WHERE k = ANY(^keys))`,
  com `keys = Event.metadata_keys()`; marca `events_pruned_at = now`. Tudo por job em `Repo.transact`.
- Mapa de retorno: `job_events` (apagados), `job_events_stripped` (reescritos), `job_telemetry`,
  `job_files` (de `Files.prune/2`). `@moduledoc` atualizado.
- `config/*.exs`: nenhum uso de `:job_events_days` hoje (só `config/test.exs` desliga o processo); conferir
  `config/runtime.exs` na implementação.

**`PipeMaestro.Insights`**: `store_summary/1` não regrava o resumo de job com `events_pruned_at`
(guarda contra recálculo a partir de eventos podados). `job/1` já lê o `insights` guardado.

**`PipeMaestro.Workspaces`**: nada novo além do changeset (o backoffice já usa `update_workspace`).

### `apps/pipe_maestro_web`

- **`PipeMaestroWeb.RunnerFileController`**: `error(conn, :quota_exceeded)` →
  `413 %{error: "quota_exceeded", quota_bytes: ...}` (4xx: o runner não repete; mesmo status do
  `too_large`, distinto pelo corpo). Recomendo 413 a 422 porque é "corpo grande demais para o limite"
  como `too_large`; o ADR registra.
- **`PipeMaestroWeb.JobFileController.show/2`**: anexo com `pruned_at` → `410` com
  `text("Este anexo foi removido pela retenção do workspace.")`.
- **`PipeMaestroWeb.JobFileComponents`**:
  - `files/1`: podados saem das miniaturas e entram na lista como item sem link, com o nome e o badge
    "removido pela retenção" (`data-testid="<testid>-pruned-<key>-<path>"`).
  - novo `files_refused_quota/1` (`.alert color="warning"`), "N arquivos recusados: a cota de anexos do
    workspace (X MiB) foi atingida", sem "veja o log do runner".
  - `files_failed/1` passa a receber `files_failed - files_refused_quota` (o runner conta os 4xx em
    `files_failed`, então a recusa por cota está dentro dele); aparece só se > 0.
- **`TaskLive.AttemptComponents`** (linha ~383): calcula `refused` e `failed` e mostra os dois avisos
  (`stage-run-files-refused-<key>-<attempt>`). A cota exibida vem do workspace atual
  (`@workspace.job_files_quota_mib`, já disponível no `TaskLive.Show` via escopo).
- **`TaskLive.NodePanel`** (aba "Anexos") e `TaskLive.PipelineView`: usam `files/1`, herdam o estado podado.
- **Eventos**: `PipeMaestroWeb.JobComponents` já tolera chaves ausentes (`data["text"]`, `Markdown.to_html(nil)`,
  cláusula genérica `event_body/1`); o plano inclui teste de renderização de cada tipo com `data` só de
  metadados. Novo componente `events_pruned/1` (`.alert color="info"`, "Conteúdo removido pela retenção",
  `data-testid="job-events-pruned"`) no topo da linha do tempo em `PipeMaestroWeb.JobLive` e em
  `TaskLive.StagePanel` (`stage-events-pruned-<key>-<attempt>`), quando `job.events_pruned_at`.
- **Backoffice** (`Backoffice.WorkspaceLive.Index`): quatro campos no formulário
  (`workspace-files-retention`, `workspace-files-quota`, `workspace-events-retention`,
  `workspace-events-after` — `.field type="select"`); card da listagem com o uso se couber
  (`workspace-files-usage-<slug>`). `Backoffice.WorkspaceLive.Show`: card "Retenção e anexos" com
  "312 MiB de 1.024 MiB" / "312 MiB, sem cota" (`workspace-files-usage`) e as políticas
  (`workspace-retention-policy`); `.progress` do Petal quando houver cota.
- **`PipeMaestroWeb.UsageLive`**: card somente leitura **abaixo** do conteúdo principal
  (`usage-files`, `usage-files-bytes`, `usage-retention`), mesmo formatador do backoffice
  (um helper compartilhado, p.ex. `RetentionComponents.files_usage/1` + `retention_policy/1`).
- Petal: `.card`, `.alert`, `.badge`, `.progress`, `.field` (conferir attrs em `docs/guias/ui-petal.md` e
  no deps antes de usar `.progress`).

### `apps/pipe_maestro_protocol` — **não muda**

Limites de `PipeMaestroProtocol.JobFiles` intocados; nenhuma mensagem de Channel muda.

### `apps/pipe_maestro_runner` — **não muda**

`PipeMaestroRunner.JobFiles.upload/5` já não repete 4xx e conta a falha em `files_failed`.

## Fronteiras

- Domínio continua sem web: cota, poda, uso e lista de metadados ficam em `PipeMaestro.*`; a web só
  formata e responde HTTP.
- Runner não ganha dependência nem código. `protocol` não muda.

## Protocolo

- `apps/pipe_maestro_protocol` **não** muda, nem os payloads dos Channels; **a versão não sobe**.
- O endpoint HTTP `PUT /api/runner/jobs/:job_id/files` ganha uma resposta nova, documentada em
  `docs/specs/protocolo-runner.md` §4.8 (tabela "As respostas"): `413 {"error": "quota_exceeded", "quota_bytes"}`
  — "o workspace atingiu a cota de anexos".
- **Runners antigos e atuais**: compatíveis sem mudança. Qualquer 4xx já é "não repete, conta em
  `files_failed`" (ADR 0042, decisão 2), e o job termina como terminaria. O control plane distingue a
  recusa por cota pela própria contagem (`files_refused_quota`), não pelo runner. Não é preciso o caminho
  de capacidade do ADR 0042 decisão 6.

## Telas e e2e

Telas tocadas: tarefa (tentativa, aba Anexos), execução (`JobLive`), linha do tempo da etapa,
backoffice (index/form e show), Uso.

Specs Playwright (`e2e/tests/`):
- `backoffice-workspaces.spec.ts`: editar os quatro campos, caso inválido com mensagem, uso no detalhe
  (`workspace-files-usage`). `e2e/pages/BackofficePage.ts` ganha os campos.
- `task-files.spec.ts` (novo teste ou spec `task-files-retention.spec.ts`): cota pequena (1 MiB) definida
  no backoffice + runner real subindo arquivo maior → aviso `stage-run-files-refused-*`; depois, helper
  novo em `e2e/helpers/e2eState.ts` (`mix run -e` no ambiente e2e, como `ensureBootstrapOperator`)
  que envelhece os anexos e o job do workspace e chama `Files.prune/2` + a poda de eventos → página
  mostra "removido pela retenção" e `job-events-pruned`; tela de Uso mostra `usage-files-bytes`.
- `make e2e.shots` em claro e escuro das telas novas; cópias em `$CP_FILES_DIR`.

## Testes (ExUnit)

`apps/pipe_maestro/test`:
- `workspaces/workspace_test.exs`: padrões, faixas válidas/ inválidas com mensagens, enum.
- `jobs/event_test.exs`: `metadata_only/1` mantém exatamente `metadata_keys/0` e tira `text`/`input`/etc.
  (um evento de cada tipo de `PipeMaestroProtocol.JobEvent`).
- `jobs/files_test.exs`: cota (abaixo, igual, acima), substituição desconta o antigo, podados não contam,
  sem cota não restringe, contador `files_refused_quota` incrementa e status do job intacto;
  concorrência: dois `store/4` em processos com `Ecto.Adapters.SQL.Sandbox` compartilhado não passam
  juntos; `prune/2` por workspace e `:batch`; reenviar caminho podado limpa `pruned_at`;
  `workspace_usage/1`.
- `maintenance_test.exs`: critérios 1–3 e 8 (metadata, delete, telemetry, dois workspaces, idempotência,
  padrão 30 dias, sem anexos podados por padrão, job antigo sem eventos não perde resumo).
- `insights_test.exs` / `usage_test.exs`: critério 4 (Usage totais, por dia, por estágio; `Audit.list_events/2`;
  `Insights.job/1` de job podado não consulta eventos — p.ex. resumo idêntico e `store_summary/1` não regrava).
- Migração: backfill testado indiretamente (job antigo sem eventos não é reprocessado).

`apps/pipe_maestro_web/test`:
- `runner_file_controller_test.exs`: 413 `quota_exceeded` com `quota_bytes`; arquivo não gravado.
- `job_file_controller_test.exs`: 410 para podado.
- `job_file_components_test.exs` / `attempt_components` via `TaskLive.Show`: "removido pela retenção" sem
  link; aviso de cota; `files_failed` descontado.
- `job_components_test.exs`: cada tipo de evento só com metadados renderiza; aviso único em `JobLive`.
- Backoffice `workspace_live_test.exs` e `usage_live_test.exs`: campos, validação, uso × cota.

## Documentação

- **ADR novo** `docs/adr/0053-retencao-por-workspace.md`: as quatro políticas e padrões; o que conta como
  metadado (lista e as chaves extras); poda por conteúdo (linha fica) e marcador `events_pruned_at`;
  resumo guardado antes da poda; cota sobre não podados, advisory lock, 413 `quota_exceeded`,
  `files_refused_quota` sem mudar protocolo; responde a questão em aberto 3.
- **ADR 0042**: consequência "Ainda não há retenção nem cota" → aponta para o 0053; resposta nova na
  lista de decisão 2.
- **`docs/plano/01-visao-arquitetura.md`**: risco (linha 223) e questão 3 marcados como respondidos pelo 0053.
- **`docs/specs/protocolo-runner.md`** §4.8: linha `413 quota_exceeded` na tabela de respostas.
- **`docs/guias/deploy.md`** (e `docs/guias/instalacao.md`, citado pelo spec): `client_max_body_size 12m;`
  está correto (10 MiB = 10.485.760 bytes < 12 MiB, com folga para cabeçalhos). Acrescentar que a recusa
  por cota não é o 413 do nginx: vem do app, com corpo JSON `quota_exceeded`, e aparece na tarefa como
  "recusados", não como "não chegaram".

## Riscos

- **Reprocessamento do histórico**: a seleção nova usa `events_pruned_at is null`; jobs já podados no
  regime antigo (sem eventos) seriam pegos e, se `store_summary/1` rodasse, o resumo seria recalculado
  **vazio**, mudando Uso/Insights. Mitigação dupla: backfill na migração e `store_summary` só quando ainda
  há eventos/telemetry, mais a guarda em `Insights.store_summary/1` para jobs podados.
- **Mudança de padrão**: depois de 30 dias, eventos passam a ficar como metadados em vez de sumir — o banco
  guarda mais linhas que hoje (pequenas). É o pedido da tarefa; o ADR registra; operador pode pôr `"delete"`.
- **Migração em tabela grande**: colunas novas com default constante são instantâneas no Postgres 16;
  índices parciais podem usar `create index concurrently` (com `@disable_ddl_transaction`) se `job_files`/`jobs`
  forem grandes — avaliar na implementação.
- **Concorrência**: ordem de locks job → advisory do workspace, sempre a mesma; a poda (update sem lock de
  job) pode correr com um `store` do mesmo arquivo — o `store` repõe `pruned_at: nil`, e a poda só toca
  `inserted_at` antigo, então não há perda de arquivo novo.
- **UPDATE em JSONB por lote**: limitado por `:batch` jobs por execução, como hoje.
- **Contagem `files_failed` vs `files_refused_quota`**: o runner soma recusas em `files_failed`; a tela
  subtrai, com `max(0, …)`.
- **Dialyzer**: `Ecto.Enum` no `@type`, `store_error` com `:quota_exceeded`, retornos novos de `run/2`.
- **Cobertura**: testes acima cobrem os ramos novos; nenhuma exclusão.
