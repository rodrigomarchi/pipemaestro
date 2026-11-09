# Etapa 3 — Implementação

O plano (`01-plano.md`) está implementado, e os testes da etapa 2 passam sem terem sido
enfraquecidos. `make ci.quick` saiu com 0: compile sem warnings, format, deps, credo e as quatro
suítes com cobertura. `mix dialyzer` também saiu com 0. O protocolo e o runner não mudaram.

Commits nesta etapa:

- `bcfab49` feat: domínio (migração, schemas, cota, poda)
- `8be96a7` feat(ui): controllers e telas
- `956f852` docs: ADR 0053 e atualizações
- o último commit de fix(ui): texto do agente podado sem balão vazio, uso pequeno em MiB, alias
  em ordem e teste de `RetentionComponents`

## O que mudou por app

### `apps/pipe_maestro`

- **Migração** `priv/repo/migrations/20261124100000_add_retention_policies.exs`:
  - `workspaces` ganha `job_files_retention_days`, `job_files_quota_mib`,
    `agent_events_retention_days` (30) e `agent_events_after_retention` (`'metadata'`), com
    check constraints;
  - `jobs` ganha `events_pruned_at` e `files_refused_quota` (0);
  - `job_files` ganha `pruned_at`, e `content` passa a aceitar `NULL`;
  - dois índices parciais;
  - backfill: os jobs que a poda global antiga já tinha esvaziado (terminados há mais de 30 dias,
    sem eventos nem telemetria) ficam marcados como podados;
  - o `down` desfaz tudo, e apaga antes os anexos já podados, que voltariam a violar o `NOT NULL`.
- **`Workspaces.Workspace`**: os quatro campos, com `agent_events_after_retention` como
  `Ecto.Enum` (`:metadata`/`:delete`), validação com mensagens em português, `@type` e
  `@moduledoc`.
- **`Jobs.Event`**: `metadata_keys/0` e `metadata_only/1`, a lista nomeada num só lugar.
- **`Jobs.Job`**: `files_refused_quota` e `events_pruned_at`. **`Jobs.JobFile`**: `pruned_at` e
  `pruned?/1`.
- **`Jobs.Files`**:
  - `store/4` confere a cota (`within_quota/3`) dentro da transação que trava o job. A conferência
    usa `pg_advisory_xact_lock` por workspace, só quando há cota, e desconta o arquivo do mesmo
    caminho e os anexos podados. Devolve `{:error, :quota_exceeded}`, e o
    `files_refused_quota` é incrementado depois do rollback.
  - Reenviar um caminho limpa `pruned_at`.
  - Funções novas: `workspace_usage/1`, `quota_bytes/1` e `prune/2` (por workspace, com
    `:batch`).
- **`Maintenance`**: o `:job_events_days` global deu lugar à política de cada workspace. O
  `run/2` devolve `job_events`, `job_events_stripped`, `job_telemetry` e `job_files`.
  - Por job, numa transação: o resumo é gravado só se ainda houver eventos ou telemetria; a
    telemetria sai; os eventos saem (`delete`) ou ficam só com os metadados (`metadata`, com um
    `UPDATE` em SQL e `jsonb_object_agg`); e o job é marcado em `events_pruned_at`.
- **`Insights.store_summary/1`**: não regrava o resumo de um job podado.

### `apps/pipe_maestro_web`

- **`RunnerFileController`**: responde `413 {"error": "quota_exceeded", "quota_bytes"}`.
- **`JobFileController`**: responde 410 para um anexo podado.
- **`JobFileComponents`**:
  - `files/1` lista o anexo podado com o nome e o badge "removido pela retenção", sem link nem
    miniatura (`<testid>-pruned-<key>-<path>`);
  - novo `files_refused_quota/1`.
- **`TaskLive.AttemptComponents`**: aviso da cota (`stage-run-files-refused-*`). O
  `files_failed` é descontado das recusas, porque o runner as conta como falhas. A aba Passos
  ganha o aviso `stage-run-events-pruned-*`. O `StagePanel` e o `Show` passam `quota_bytes`.
- **`JobComponents`**: novo `events_pruned/1`. O `assistant_text` sem texto não desenha mais um
  balão vazio. **`JobLive`**: aviso único `job-events-pruned`.
- **Novo `RetentionComponents`**: `format_mib/1` (no formato pt-BR, "< 0,1 MiB" para uso muito
  pequeno), `usage_label/1`, `files_usage/1` (texto e `.progress`) e `retention_policy/1`.
- **Backoffice**:
  - o formulário tem os quatro campos (`workspace-files-retention`, `workspace-files-quota`,
    `workspace-events-retention`, `workspace-events-after`);
  - o detalhe ganha o card "Anexos e retenção" (`workspace-files-usage`,
    `workspace-retention-policy`);
  - a listagem não ganhou o uso por workspace: o pedido dizia "se couber", e mostrá-lo pediria
    uma soma por workspace na listagem.
- **`UsageLive`**: o card "Anexos e retenção", somente leitura, no fim da aba Visão geral, abaixo
  do conteúdo principal (`usage-files`, `usage-files-bytes`, `usage-retention`).

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`

Nenhum dos dois mudou. O runner já não repete um 4xx, então runners antigos e novos tratam o 413
de cota igual. A versão do protocolo não sobe.

### Documentação

- O ADR novo `docs/adr/0053-retencao-por-workspace.md` entrou no índice `docs/README.md`.
- ADR 0042: a consequência "Ainda não há retenção nem cota" agora aponta para o ADR 0053.
- `docs/plano/01-visao-arquitetura.md`: a restrição e a questão em aberto 3 estão marcadas como
  respondidas.
- `docs/specs/protocolo-runner.md` §4.8: nova linha `413 quota_exceeded`.
- `docs/guias/deploy.md` e `docs/guias/instalacao.md`: o `client_max_body_size 12m;` está
  correto, e uma recusa por cota não é o 413 do nginx.

## Testes ajustados (e por quê)

- `task_live_test.exs`, "a stage whose events the retention emptied…": o teste usava
  `List.last(stage_runs).job`. Depois que a etapa `a` termina, essa é a tentativa da etapa `b`,
  que ainda roda, e por isso nunca é podada. O teste agora pega o job da etapa `a`. A asserção
  não mudou.
- O teste de domínio esperava "não pode ficar em branco". O domínio não traduz mensagens (o
  Gettext fica na web), então o `validate_required` dos campos novos passa a mensagem explícita.
  O teste não mudou.
- Novo `components/retention_components_test.exs`, com a formatação em MiB e as frases das
  políticas.

## Como verificar

- `mix test apps/pipe_maestro/test/pipe_maestro/{maintenance,insights,workspaces}_test.exs apps/pipe_maestro/test/pipe_maestro/jobs/`
- `mix test apps/pipe_maestro_web/test/pipe_maestro_web/controllers/{runner_file,job_file}_controller_test.exs apps/pipe_maestro_web/test/pipe_maestro_web/live/{task_live,job_live,usage_live}_test.exs apps/pipe_maestro_web/test/pipe_maestro_web/live/backoffice/workspace_live_test.exs`
- e2e: `make e2e FILE=tests/task-files-retention.spec.ts` passa, e os specs vizinhos também:
  `task-files`, `backoffice-workspaces`, `job-execution` e `task-stage-panel`.
- Screenshots em claro e escuro (`make e2e.shots FILE=tests/task-files-retention.spec.ts`), copiadas para
  `$CP_FILES_DIR/screenshots/`. Mostram o backoffice com uso e políticas, a tela de Uso com o
  bloco abaixo do conteúdo, o aviso de cota, os anexos podados na tentativa e na aba Anexos, e os
  Passos com o aviso de retenção.

## Observação

`IntegrationLiveTest` "repository sync reads the issues on demand" falhou uma vez na suíte do app
web: o `render_async` tem 100 ms de prazo. O teste passou sozinho e no `ci.quick`. É
intermitente, e não vem desta mudança.
