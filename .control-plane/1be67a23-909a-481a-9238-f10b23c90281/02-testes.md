# Etapa 2 — Testes que falham

Base: `origin/main` sem novidades. A branch tem só o plano (f6ca3c0) antes desta etapa.

Os testes seguem o plano (`01-plano.md`). Nenhum código de produção mudou. Os campos novos dos schemas
são lidos com `Map.get/2,3` e gravados por `Workspaces.update_workspace/2`. Hoje o `cast` ignora as
chaves desconhecidas, então os testes compilam e falham por asserção. As funções novas falham por
`UndefinedFunctionError`.

## Testes escritos

### `apps/pipe_maestro` (ExUnit)

| Arquivo | O que prova |
|---|---|
| `test/pipe_maestro/workspaces_test.exs` (describe "retention policies") | padrões (`nil`, `nil`, 30, `:metadata`); valores válidos gravados e limpos (`nil`); faixas inválidas com mensagens: "use de 1 a 3650 dias", "use um número positivo", "não pode ficar em branco", "escolha manter só os metadados ou apagar" |
| `test/pipe_maestro/jobs/event_test.exs` (novo) | `Event.metadata_keys/0` é a lista nomeada; `Event.metadata_only/1` mantém só ela em `tool_use`, `tool_result`, `result`, `assistant_text` e `thinking`, e tira `text`, `input`, `arguments`, `structured_output`, `todos` e `decision` |
| `test/pipe_maestro/jobs/files_test.exs` (describes "the workspace's quota" e "prune/2") | cota: recusa acima dela e aceita o que a enche exatamente; conta a recusa em `jobs.files_refused_quota` sem mudar o status do job; a substituição desconta o arquivo antigo; anexos podados não contam; a soma é do workspace inteiro; sem cota, nada muda; `workspace_usage/1`. Poda: tira o conteúdo e mantém `path`, `byte_size`, `content_type` e `pruned_at`; é idempotente; sem retenção nada some; cada workspace segue o próprio prazo; respeita `:batch`; reenviar um caminho podado traz o conteúdo de volta; `JobFile.pruned?/1` |
| `test/pipe_maestro/maintenance_test.exs` (describes "the agent events' retention, per workspace" e "the files' retention") | critério 1: com `metadata`, mesmos `seq` e `type` e só metadados; o job fica marcado e a segunda execução não toca nele (`job_events_stripped: 0`). Critério 2: com `delete`, os eventos somem; a `Telemetry` some nas duas políticas. Critério 3: dois workspaces com prazos diferentes no mesmo `run/2`. `:batch`. Um job podado no regime antigo mantém o resumo. Critério 4: `Usage.report/2`, a contagem de `Audit.list_events/2` e `Insights.job/1` ficam iguais antes e depois da poda, e `store_summary/1` não regrava o resumo. Critério 8: por padrão, nenhum anexo perde o conteúdo. `job_files` no mapa de `run/2` |
| `test/pipe_maestro/insights_test.exs` | novo: o resumo guardado sobrevive à poda `metadata` e não é recalculado. Os dois testes antigos que esperavam os eventos apagados agora configuram `agent_events_after_retention: "delete"` |

O teste antigo `maintenance_test.exs` "removes stale sign-in requests…" passa a configurar `"delete"`.
Ele continua verde hoje e depois da mudança do padrão.

### `apps/pipe_maestro_web` (ExUnit)

| Arquivo | O que prova |
|---|---|
| `controllers/runner_file_controller_test.exs` | `PUT` além da cota → `413 {"error": "quota_exceeded", "quota_bytes": 1048576}`; o arquivo não é gravado; `files_refused_quota` = 1; a substituição desconta o arquivo antigo |
| `controllers/job_file_controller_test.exs` | download de anexo podado → 410 com "removido pela retenção" |
| `live/task_live_test.exs` | anexo podado: `stage-run-file-pruned-a-1-<path>` com o nome e "removido pela retenção", sem download nem miniatura, também na aba Anexos (`task-attachment-pruned-…`). Cota: `stage-run-files-refused-a-1` diz "2 arquivos recusados: a cota de anexos do workspace (1 MiB) foi atingida", sem "log do runner", e `files_failed` fica descontado ("1 arquivo não chegou"); a etapa termina "Concluída". Eventos podados: a aba Passos mostra `stage-run-events-pruned-a-1` |
| `live/job_live_test.exs` | um job com os 10 tipos de evento, podado com `metadata`, renderiza sem exceção; um único `job-events-pruned`; "10 eventos"; a ferramenta "Bash" continua visível; nenhum texto ("segredo") aparece. Um job com os eventos inteiros não mostra o aviso |
| `live/backoffice/workspace_live_test.exs` | o formulário tem `workspace-files-retention`, `workspace-files-quota`, `workspace-events-retention` e `workspace-events-after`; três casos inválidos com mensagem; a gravação dos quatro campos. O detalhe mostra `workspace-files-usage` ("2 MiB, sem cota" e depois "2 MiB de 1.024 MiB") e `workspace-retention-policy` |
| `live/usage_live_test.exs` | bloco somente leitura: `usage-files-bytes` ("sem cota" e "2 MiB de 1.024 MiB") e `usage-retention` ("30 dias", "metadados", "sem limite", "90 dias", "apagados"), sem formulário |

### e2e (Playwright)

- `e2e/tests/task-files-retention.spec.ts` (novo, fluxos A, B e C). O operador define a retenção e a cota
  de 1 MiB, e o detalhe e a tela de Uso mostram o uso contra a cota. Uma segunda tarefa, com a cota
  cheia, tem os arquivos recusados com o aviso próprio e termina "Concluída". Depois da retenção, os
  anexos aparecem sem link, o download responde 410, os Passos mostram o aviso e a aba Anexos mostra
  o anexo podado. O spec captura screenshots para `make e2e.shots`.
- `e2e/pages/BackofficePage.ts`: `setRetention`, `filesUsage` e `retentionPolicy`.
  `e2e/pages/TasksPage.ts`: `stageRunFilePruned`, `stageRunFilesRefused`, `stageRunEventsPruned` e
  `attachmentPruned`. Novo `e2e/pages/UsagePage.ts`.
- `e2e/helpers/e2eState.ts`: `inflateJobFile` enche a cota com os arquivos pequenos do agente falso, e
  `expireRetention` envelhece os anexos e os jobs do workspace e roda `Maintenance.run/2`. Os dois
  usam `mix run` no ambiente e2e, como `ensureBootstrapOperator`.

Textos que a implementação precisa usar, porque os testes conferem: "removido pela retenção",
"conteúdo removido pela retenção" (em minúsculas, dentro do aviso), "N arquivos recusados: a cota
de anexos do workspace (X MiB) foi atingida", "X MiB de 1.024 MiB" e "X MiB, sem cota".

## Execução: falham pelo motivo certo

`mix format --check-formatted`: ok. `make e2e.typecheck`: ok.

### Domínio: `mix test` dos cinco arquivos → 29 falhas, 38 passam (log em `tmp/t-domain.log`)

```
1) test metadata_keys/0 … (PipeMaestro.Jobs.EventTest)
   ** (UndefinedFunctionError) function PipeMaestro.Jobs.Event.metadata_keys/0 is undefined or private
6) test retention policies refuse values out of range … (PipeMaestro.WorkspacesTest)
   code:  assert {:error, changeset} = Workspaces.update_workspace(workspace, attrs)
   right: {:ok, %PipeMaestro.Workspaces.Workspace{…
8) test retention policies default to no limit … (PipeMaestro.WorkspacesTest)
   code:  assert Map.get(workspace, :job_files_retention_days, :missing) == nil
   left:  :missing
16) test the workspace's quota refuses the file that would take the workspace past it
   code:  assert Files.store(…, "b.bin", kib(600)) == {:error, :quota_exceeded}
   left:  {:ok, %PipeMaestro.Jobs.JobFile{…
9) test prune/2 a workspace without retention keeps every file, however old
   ** (UndefinedFunctionError) function PipeMaestro.Jobs.Files.prune/1 is undefined or private
22) test prune/2 pruned?/1 tells an emptied file apart
   ** (UndefinedFunctionError) function PipeMaestro.Jobs.JobFile.pruned?/1 is undefined or private
12) test … by default, past 30 days, keeps every event with only its metadata (MaintenanceTest)
   code:  assert %{job_events: 0, job_events_stripped: 5, job_telemetry: 1} = Maintenance.run(…)
   (hoje os eventos são apagados e a chave job_events_stripped não existe)
23) test … at most :batch jobs per run   left: 0  right: 2   (não há events_pruned_at)
14) test the kept summary outlives the events' content … (InsightsTest)
   code:  assert %DateTime{} = Map.get(job, :events_pruned_at)   right: nil
```

Por que essas são as falhas esperadas: os campos, as colunas e as funções ainda não existem, a cota
não é aplicada e o `Maintenance` ainda poda de forma global, apagando os eventos. Nenhuma falha vem de
sintaxe, de setup ou de fixture: o setup cria workspace, runner, tarefa e job normalmente.

Os testes que passam hoje e precisam continuar passando são guardas de regressão. São eles: "a job of
the old retention, with nothing left, keeps its summary", "replacing a path discounts…" (sem cota não
há recusa) e todos os testes antigos dos arquivos tocados.

### Web: `mix test` dos seis arquivos → 9 falhas, 74 passam (log em `tmp/t-web.log`)

```
1) 410 for a file the retention emptied   ** (UndefinedFunctionError) … Files.prune/1 is undefined
2) usage files/retention   Expected truthy, got false   has_element?(view, "[data-testid=usage-files-bytes]", "sem cota")
3) backoffice edits the four policies   Expected truthy, got false   has_element?(view, "[data-testid=workspace-files-retention]")
4) 413 quota_exceeded   ** (RuntimeError) expected response with status 413, got: 201
5) backoffice files usage   Expected truthy, got false   "[data-testid=workspace-files-usage]"
6) job live pruned events   Expected truthy, got false   "[data-testid=job-events-pruned]"
7) task file pruned   ** (UndefinedFunctionError) … Files.prune/1 is undefined
8) task steps pruned   Expected truthy, got false   "[data-testid=stage-run-events-pruned-a-1]"
9) task quota refused   ** (MatchError) no match of right hand side value: {:ok, %JobFile{…}}  (a cota não recusa)
```

Os elementos, os status HTTP e as funções novos ainda não existem. Os testes antigos de cada arquivo
continuam verdes.

### e2e: `make e2e FILE=tests/task-files-retention.spec.ts` → exit 2 (log em `tmp/e2e.log`)

```
TimeoutError: locator.fill: Timeout 10000ms exceeded.
  - waiting for getByTestId('workspace-files-retention')
  at BackofficePage.setRetention (pages/BackofficePage.ts:100)
```

É a falha esperada: o formulário do backoffice ainda não tem os campos de retenção. O resto do fluxo
(login, runner real, tarefas) é o mesmo de `task-files.spec.ts`, que já passa.

## Para a implementação

- Os nomes do retorno de `Maintenance.run/2`: `job_events` (apagados), `job_events_stripped`
  (reescritos), `job_telemetry` e `job_files` (podados).
- `Files.prune/2` com assinatura `prune(now, opts \\ [])` e `batch:`. `Files.workspace_usage/1` →
  `%{bytes:, quota_bytes:}`. `JobFile.pruned?/1`. `Event.metadata_keys/0` e `Event.metadata_only/1`.
- `agent_events_after_retention` como `Ecto.Enum` (`:metadata`, `:delete`); os testes comparam átomos.
- Não há teste de concorrência entre dois uploads simultâneos: no sandbox do Ecto, os dois processos
  dividem a mesma conexão, e o advisory lock é reentrante na mesma sessão. O teste não provaria nada.
  O lock fica coberto por revisão e pelo ADR.
