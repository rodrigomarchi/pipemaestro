# Testes que falham — sessões do Claude CLI com o worktree

Os testes fixam a API do plano (`01-plano.md`). Nenhum código de produção foi escrito.
Nenhuma tela nova, então sem spec Playwright: a única mudança visível é o rótulo do evento,
coberto por teste de LiveView.

## Arquivos

| Arquivo | O que descreve |
|---|---|
| `apps/pipe_maestro_runner/test/pipe_maestro_runner/claude_sessions_test.exs` (novo) | `ClaudeSessions`: `dir_name/1` (`.`, `_`, espaço, UTF-16, corte em 200 + hash, contra valores calculados com a função do CLI 2.1.319), `real_path/1` com symlink e `/tmp` → `/private/tmp`, `task_cwd/2` com o worktree já apagado, `projects_root/1` e `project_dir_override?/1` com env em mapa, marcador `mark/marked?/forget`, `bytes/2` e `remove/3`: só as sessões da tarefa saem; outra tarefa, `...-<task>-x`, cwd do dev, `memory/`, entradas não-UUID e symlink ficam; bytes liberados = soma medida antes; `cwd` estranho (no `.jsonl` ou em `subagents/`) → `:cwd_mismatch` sem apagar nada; `:not_found`; só subdiretórios saem; `:shared_project_dir` |
| `apps/pipe_maestro_runner/test/pipe_maestro_runner/disk_test.exs` | `Disk.usage/2` soma as sessões dos worktrees existentes (não as de outro cwd) e o valor cai depois de `remove/3` |
| `apps/pipe_maestro_runner/test/pipe_maestro_runner/job_runner_test.exs` | opção `claude_projects`; job com `persist_session` marca a tarefa; `remove_worktree` apaga a sessão e o marcador, mantém o diretório de prefixo igual; marcada sem sessão → `worktree:removed` sem `error` + evento `claude_sessions_not_found` com `task_id`, `dir`, `reason: "not_found"`, `cli_version`; tarefa sem marcador → sem evento. O evento é observado por um handler de `:logger` (`EventSpy`), filtrado pelo `dir` do teste porque a suíte é `async` |
| `apps/pipe_maestro_runner/test/test_helper.exs` | `CLAUDE_CONFIG_DIR` aponta para um diretório temporário e `CLAUDE_CODE_PROJECT_DIR_NAME` é apagado: nenhum teste toca o `~/.claude` real |
| `apps/pipe_maestro_protocol/test/pipe_maestro_protocol/runner_log_test.exs` | `claude_sessions_not_found` em `RunnerLog.events/0` e preservado no `parse/1` |
| `apps/pipe_maestro/test/pipe_maestro/runner_telemetry_test.exs` | a linha vira `%Event{kind: "claude_sessions_not_found", task_id: <attrs.task_id>}`, no grupo `worktree` |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/runner_live_test.exs` | `LogTab.kind_label/1` → `"sessões do claude não encontradas"` |

## Falhas observadas (e por que são as certas)

**Runner** — `cd apps/pipe_maestro_runner && mix test test/pipe_maestro_runner/{claude_sessions,disk,job_runner}_test.exs`:
`Result: 59/81 passed — Failed: 22 tests`. Os 22 são os novos, todos por função inexistente:

```
 1) test the space counts the CLI's sessions of each worktree, and drops when they go (PipeMaestroRunner.DiskTest)
    ** (UndefinedFunctionError) function PipeMaestroRunner.Disk.usage/2 is undefined or private.
 8) test dir_name/1 every character outside [A-Za-z0-9] becomes a dash (PipeMaestroRunner.ClaudeSessionsTest)
    ** (UndefinedFunctionError) function PipeMaestroRunner.ClaudeSessions.dir_name/1 is undefined (module PipeMaestroRunner.ClaudeSessions is not available)
20) test removing a worktree the task's CLI sessions go with its worktree (PipeMaestroRunner.JobRunnerTest)
    ** (UndefinedFunctionError) function PipeMaestroRunner.ClaudeSessions.marked?/2 is undefined (module PipeMaestroRunner.ClaudeSessions is not available)
22) test removing a worktree a kept session not found: the worktree goes all the same, and an event tells it (PipeMaestroRunner.JobRunnerTest)
    ** (UndefinedFunctionError) function PipeMaestroRunner.ClaudeSessions.marked?/2 is undefined ...
```

Esperado: o módulo `ClaudeSessions` e `Disk.usage/2` ainda não existem. Os 59 testes vizinhos
(incluindo os de remoção de worktree já existentes) passam com o `CLAUDE_CONFIG_DIR` temporário.

**Protocolo** — `Result: 5/6 passed`:

```
1) test the CLI's sessions not found where expected are an event (PipeMaestroProtocol.RunnerLogTest)
   code:  assert "claude_sessions_not_found" in RunnerLog.events()
   left:  "claude_sessions_not_found"
   right: ["update_applied", "update_failed", "update_draining", ...
```

Esperado: o evento ainda não está em `@events`.

**Domínio** — `Result: 21/22 passed`:

```
1) test log and events the CLI's sessions not found are a worktree event of the task (PipeMaestro.RunnerTelemetryTest)
   code:  assert [%Event{kind: "claude_sessions_not_found", task_id: ^task_id}] =
   right: []
```

Esperado: `RunnerLog.line/5` descarta o evento desconhecido, então nenhum `Event` é gravado;
depois de entrar no protocolo, falta ainda o grupo em `Event` e o `task_id` em `record_log/2`.

**Web** — `Result: 18/19 passed`:

```
1) test tabs the CLI's sessions not found show with their label (PipeMaestroWeb.RunnerLiveTest)
   left:  "claude_sessions_not_found"
   right: "sessões do claude não encontradas"
```

Esperado: `kind_label/1` cai na cláusula genérica.

## Notas para a implementação

- `remove/3` recebe o env como terceiro argumento (mapa) para o override
  `CLAUDE_CODE_PROJECT_DIR_NAME`; os testes passam `%{}`.
- `Disk.usage/2`: segundo argumento é a raiz dos projetos; `usage/1` continua existindo (default).
- `JobRunner` aceita `claude_projects:`; o marcador é `<workdir>/worktrees/<task_id>.claude-sessions`.
- Os valores com hash vieram da função `hD` do CLI 2.1.319 rodada em `node`.
