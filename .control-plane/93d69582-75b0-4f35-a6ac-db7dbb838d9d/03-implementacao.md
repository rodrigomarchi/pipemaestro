# Implementação — sessões do Claude CLI saem com o worktree da tarefa

Os testes da etapa 2 passam sem mudança de asserção. A única edição neles foi um alias
(`PipeMaestroWeb.RunnerLive.LogTab`) que o Credo pediu em `runner_live_test.exs`.

## O que mudou por app

### `pipe_maestro_runner`

- **`PipeMaestroRunner.ClaudeSessions`** (novo, `lib/pipe_maestro_runner/claude_sessions.ex`).
  O moduledoc traz o formato do CLI 2.1.319, as regras de remoção e a heurística do evento.
  - `projects_root/1`: `CLAUDE_CONFIG_DIR` (vazio conta como ausente) ou `~/.claude`, mais `projects`.
  - `project_dir_override?/1`: diretório fixo por `CLAUDE_CODE_PROJECT_DIR_NAME`.
  - `dir_name/1`: codificação por unidade UTF-16; corte em 200 caracteres + hash int32 em base 36.
  - `project_dir/2`.
  - `real_path/1`: resolve symlink por componente, com limite de saltos, e normaliza em NFC.
  - `task_cwd/2`: resolve o pai, então vale com o worktree já apagado.
  - Marcador `<workdir>/worktrees/<task_id>.claude-sessions`: `mark/2`, `marked?/2`, `forget/2`.
  - `bytes/2`, `transcript?/2` e `remove/3`: só entradas `<uuid>.jsonl` e `<uuid>/` reais, com
    verificação do `cwd` das transcrições e das transcrições de subagentes. O diretório sai só
    se ficar vazio.
  - `clean/4`: aplica a heurística e devolve `{:unexpected, reason, bytes}` quando é caso de evento.
- **`PipeMaestroRunner.JobRunner`**:
  - Nova opção `:claude_projects`.
  - `prepare/5` marca a tarefa quando o job tem `worktree` e `persist_session` ou `resume_session_id`.
  - `remove_in_background/3` resolve o cwd antes de remover o worktree. Se a remoção deu `:ok`,
    roda `clean_sessions/3`, que limpa e apaga o marcador. No caso de evento, `Logger.warning`
    com `runner_event: "claude_sessions_not_found"` e `event_attrs` `task_id`, `dir`, `reason`
    e `cli_version`. Uma exceção vira o mesmo evento com `reason: "error"`.
  - A resposta `worktree:removed` não ganha `error` por causa das sessões.
- **`PipeMaestroRunner.Disk.usage/2`**: `bytes` = `du` dos worktrees + `ClaudeSessions.bytes/2` de
  cada worktree existente. `usage/1` continua existindo, com a raiz padrão.
- **`test/test_helper.exs`**: `CLAUDE_CONFIG_DIR` temporário, para nenhum teste tocar o `~/.claude` real.
- **`PipeMaestroRunner.GateCache`**: correção de um teste intermitente que já existia
  (`GatesTest` "a change to the tree runs it again", falhava cerca de 1 vez em 5).
  - Causa: o índice é copiado e ganha mtime de agora. Um arquivo reescrito no mesmo segundo
    do índice, com o mesmo tamanho, deixava de ser "racy" e o git o via como inalterado.
  - O `with` que deveria ajustar a hora não chegava a rodar, porque `File.cp/2` devolve `:ok`
    e não `{:ok, _}`.
  - Agora a cópia fica com mtime um segundo antes do do índice (`File.stat` com
    `time: :posix` trunca o valor).
  - A cópia agora fica no git dir do repositório, com nome aleatório, e não em
    `System.tmp_dir!()` com `unique_integer`, que só é único dentro de uma VM.
  - Reprodução fora da suíte: 3 falhas em 40 antes, 0 depois.

### `pipe_maestro_protocol`

- `PipeMaestroProtocol.RunnerLog`: `claude_sessions_not_found` em `@events`. Mensagens iguais e
  `protocol_version` igual.
- Runner antigo: nunca manda o evento. Control plane antigo: `RunnerLog.parse/1` já descarta
  evento desconhecido e guarda a linha como log comum. Esse comportamento já existia e não
  precisou de teste novo.

### `pipe_maestro`

- `PipeMaestro.RunnerTelemetry.Event`: grupo `worktree` para o evento.
- `PipeMaestro.RunnerTelemetry.record_log/2`: `task_id` lido de `attrs`, como já se fazia com `job_id`.
  A coluna existe e não tem FK.

### `pipe_maestro_web`

- `PipeMaestroWeb.RunnerLive.LogTab.kind_label/1`: "sessões do claude não encontradas". Nenhuma
  outra mudança de tela, então não rodei e2e.

### Documentação

- Novo `docs/adr/0053-apagar-as-sessoes-do-cli-com-o-worktree.md`, listado em `docs/README.md`.
- `docs/adr/0041-…`: na seção Consequências, a pendência agora aponta para o ADR 0053.
- `docs/adr/0039-…`: o evento novo entra na lista.
- `docs/specs/protocolo-runner.md`:
  - `worktree:remove` passa a apagar as sessões;
  - `bytes` do `worktree:usage` inclui as sessões;
  - o evento entra na lista do `runner:log`.

## Como verificar

```sh
cd apps/pipe_maestro_runner && mix test test/pipe_maestro_runner/claude_sessions_test.exs \
  test/pipe_maestro_runner/disk_test.exs test/pipe_maestro_runner/job_runner_test.exs \
  test/pipe_maestro_runner/gates_test.exs
cd apps/pipe_maestro_protocol && mix test test/pipe_maestro_protocol/runner_log_test.exs
cd apps/pipe_maestro && mix test test/pipe_maestro/runner_telemetry_test.exs
cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/live/runner_live_test.exs
make ci.quick
```

Manualmente, num runner real: rode uma tarefa com etapa `context: continue`, confira
`~/.claude/projects/<workdir codificado>-worktrees-<task_id>/`, remova o worktree pela tela e veja o
diretório sumir e o "espaço dos worktrees" cair.
