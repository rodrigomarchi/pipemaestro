# Plano — apagar as sessões do Claude CLI quando o runner remove o worktree da tarefa

Base: `origin/main` em `225fdfd` (fast-forward; a branch não tinha commits próprios).

## Entendimento

Com `persist_session` ou `resume_session_id` (ADR 0041, `PipeMaestroRunner.Claude.session/1`),
o `claude` grava a transcrição da etapa em `<raiz>/projects/<cwd codificado>/`. Quando o
runner remove o worktree da tarefa (`worktree:remove`), essas sessões ficam para trás. A
mudança faz o runner apagá-las junto com o worktree, contar o espaço delas no
`worktree:usage` e avisar na telemetria do runner quando não as encontra onde esperava.

Quem usa percebe três coisas:

- o disco da máquina do runner para de acumular `~/.claude/projects/...-worktrees-<task_id>`;
- o "espaço dos worktrees" no runner passa a incluir as sessões e cai quando a tarefa sai;
- se uma versão futura do CLI mudar o lugar das sessões, aparece o evento
  "sessões do claude não encontradas" na aba de log do runner, e a remoção segue normal.

### O que o CLI instalado faz (2.1.319, lido no binário `~/.local/share/claude/versions/2.1.319`)

Confirmado no código do CLI, não só observado:

- **Raiz**: `(CLAUDE_CONFIG_DIR ?? ~/.claude)` normalizado em NFC, mais `projects`.
  `??` em JS: um `CLAUDE_CONFIG_DIR=""` vira raiz vazia (caminho relativo). O runner trata
  vazio como ausente.
- **Nome do diretório** (`hD`): `cwd.replace(/[^a-zA-Z0-9]/g, "-")`, aplicado a cada unidade
  UTF-16 (um caractere fora do BMP vira `--`). **Se o resultado passa de 200 caracteres**, vira
  `slice(0, 200) + "-" + Math.abs(hash(cwd)).toString(36)`, em que `hash` é o hash estilo Java
  (`h = (h << 5) - h + charCode | 0`, int32) sobre as unidades UTF-16 do caminho original.
- **Caminho real**: o cwd passa por `realpath` e NFC antes de codificar (`/tmp` → `/private/tmp`).
- **Override**: com `CLAUDE_CONFIG_DIR` definido, `CLAUDE_CODE_PROJECT_DIR_NAME`
  (`^[A-Za-z0-9_-]{1,64}$`) substitui o nome derivado do cwd: todas as tarefas iriam para um
  mesmo diretório. Nesse caso o runner **não apaga nada** (o diretório é compartilhado).
- **Conteúdo** (observado nesta máquina): `<session_id>.jsonl` e `<session_id>/` com
  `tool-results/` e `subagents/`. Jobs com `--no-session-persistence` **também** deixam
  `<uuid>/tool-results/` (vários diretórios órfãos aqui só têm subdiretórios). O diretório de
  um projeto pode ter ainda `memory/` (memória automática do CLI), que nunca é tocado.
- **`cwd` das linhas do `.jsonl`**: é o cwd do shell do agente no momento, então aparece o
  worktree **ou um subdiretório dele** (`.../<task_id>/apps/pipe_maestro/lib/...`).

### Critérios de aceite (verificáveis)

1. Depois de `worktree:remove` de uma tarefa com sessão persistida ou continuada, o diretório
   `<raiz>/projects/<nome da tarefa>` não tem mais `*.jsonl` nem `<uuid>/`, e sai se ficou vazio.
2. Diretórios de outra tarefa, de prefixo igual (`...-<task_id>-x`), de outro cwd e entradas
   desconhecidas (`memory/`) ficam intactos.
3. `worktree:usage.bytes` inclui as sessões dos worktrees que existem e cai depois da remoção.
4. Sessão esperada e não encontrada (ou conteúdo que não confere): `worktree:removed` sem
   `error` e evento `claude_sessions_not_found` no log do runner.
5. Versão testada (2.1.319) registrada no moduledoc e no ADR.
6. `make ci` verde.

## Mudanças por app

### `pipe_maestro_runner` (o grosso)

**Novo `PipeMaestroRunner.ClaudeSessions`** (`lib/pipe_maestro_runner/claude_sessions.ex`),
`@moduledoc` com o formato acima, a versão testada e a heurística do evento; `@spec` em tudo:

- `projects_root(env \\ System.get_env()) :: Path.t()` — `CLAUDE_CONFIG_DIR` não vazio, senão
  `~/.claude`; mais `projects`; NFC. Recebe o env como mapa para o teste não mexer no global.
- `project_dir_override?(env)` — `CLAUDE_CONFIG_DIR` e `CLAUDE_CODE_PROJECT_DIR_NAME` válidos.
- `dir_name(cwd) :: String.t()` — a codificação acima, sobre o caminho já resolvido (UTF-16 via
  `:unicode.characters_to_binary/3`, hash int32 com wrap, base 36 minúscula).
- `real_path(path) :: Path.t()` — resolve symlinks componente a componente
  (`:file.read_link_all/1`, `Path.expand/2`, com limite de saltos), NFC no fim.
- `task_cwd(workdir, task_id) :: Path.t()` — caminho real de `<workdir>/worktrees` mais o
  `task_id`. Resolve **o pai**, não o worktree: funciona mesmo depois que o worktree saiu, mas
  é calculado antes da remoção, como pede a tarefa.
- `mark(workdir, task_id)`, `marked?(workdir, task_id)`, `forget(workdir, task_id)` — o marcador
  `<workdir>/worktrees/<task_id>.claude-sessions` (arquivo vazio, ao lado do `<task_id>.json` de
  `PipeMaestroRunner.Changes.base_file/2`). Registra que algum job da tarefa rodou com
  `persist_session` ou `resume_session_id` neste runner.
- `bytes(root, cwd) :: non_neg_integer()` — soma (via `File.lstat`, recursivo, sem seguir
  links) das entradas que `remove/2` apagaria.
- `remove(root, cwd) :: {:ok, non_neg_integer()} | {:error, reason}` com
  `reason :: :not_found | :no_transcript | :cwd_mismatch | :shared_project_dir`.

**Regras de segurança de `remove/2`:**

1. Só o caminho `Path.join(root, dir_name(cwd))`, nome exato; nada de glob ou prefixo.
   Confere que o resultado é filho direto de `root` (nome sem `/`, sem `..`).
2. Entradas candidatas: só `UUID.jsonl` (arquivo regular) e `UUID/` (diretório real, não link),
   com regex de UUID. Qualquer outra entrada (`memory/`, arquivos desconhecidos) fica.
3. Verificação de dono: lê os `cwd` de todo `*.jsonl` candidato e de
   `UUID/subagents/*.jsonl` (stream por linha, decodifica só linhas com `"cwd"` usando `JSON`).
   Todo `cwd` precisa ser o worktree ou começar com `worktree <> "/"`. Um `cwd` estranho =
   `{:error, :cwd_mismatch}` e **nada é apagado**. Sem nenhum `.jsonl`, vale só o nome exato.
4. Apaga as candidatas (`File.rm_rf` por entrada), devolve os bytes medidos antes, e
   `File.rmdir` no diretório do projeto (só sai se vazio).
5. Com `project_dir_override?` verdadeiro: `{:error, :shared_project_dir}`, nada apagado.
6. Diretório ausente: `{:error, :not_found}`. Diretório sem `.jsonl` algum: apaga os `UUID/`
   e devolve `{:ok, bytes}`; o chamador decide se isso é anomalia (ver heurística).

**Heurística do evento** (no moduledoc): emite `claude_sessions_not_found` só se a tarefa está
marcada (`marked?`) **e** (diretório ausente **ou** sem nenhum `UUID.jsonl` **ou** `cwd` que não
confere **ou** override de nome compartilhado). Tarefa sem marcador não gera evento, mas as
sobras dela (`UUID/tool-results` de jobs sem persistência) são apagadas do mesmo jeito.
Limitação documentada: um segredo do workspace chamado `CLAUDE_CONFIG_DIR` muda a raiz só
para o job; o runner procura na raiz dele, não acha, e o evento aparece.

**`PipeMaestroRunner.JobRunner`** (`job_runner.ex`):

- `init/1`: novo `claude_projects` no estado (`Keyword.get_lazy(opts, :claude_projects,
  &ClaudeSessions.projects_root/0)`), para os testes apontarem para um diretório temporário.
- `prepare/5` (a função que roda em task): depois de `Workspace.prepare/3`, se o job tem
  `worktree` e (`persist_session: true` ou `resume_session_id`), `ClaudeSessions.mark/2`.
- `remove_in_background/3`: calcula `cwd = ClaudeSessions.task_cwd(workdir, task_id)` e
  `marked?` **antes** de `Workspace.remove_task_worktree/4`; se a remoção do worktree deu `:ok`,
  chama `clean_sessions/…` (privada) que roda `ClaudeSessions.remove/2`, apaga o marcador e,
  pela heurística, registra `Logger.warning(..., runner_event: "claude_sessions_not_found",
  event_attrs: %{"task_id", "dir", "reason", "cli_version"})`, a versão vinda de
  `Claude.agent(state.executable)["cli_version"]` (só quando o evento sai). Qualquer exceção
  nesse trecho é capturada **e registrada** como o mesmo evento com `reason: "error"`; a resposta
  continua `%{"task_id" => id}` sem `error`. Se a remoção do worktree falhou, as sessões ficam
  (a tarefa ainda pode retomar a sessão).
- `Workspace.remove_task_worktree/4` não muda de assinatura; o marcador sai em
  `ClaudeSessions.forget/2`, chamado pelo `JobRunner` depois da limpeza.

**`PipeMaestroRunner.Disk.usage/1` → `usage(workdir, claude_projects \\ ClaudeSessions.projects_root())`:**
`bytes` = `du -sk worktrees` (como hoje) + `ClaudeSessions.bytes(root, task_cwd(workdir, name))`
para cada worktree contado. Mesmo formato de mapa. Chamadores: `Connection` (`connection.ex:505`)
e `Doctor` (`doctor.ex:196`) seguem com o default.

**`test/test_helper.exs`**: aponta `CLAUDE_CONFIG_DIR` para um diretório temporário criado
na hora, como rede de segurança: nenhum teste lê ou escreve no `~/.claude` real.

### `pipe_maestro_protocol`

- `PipeMaestroProtocol.RunnerLog`: `claude_sessions_not_found` entra em `@events`. Só isso.
- `PipeMaestroProtocol.Worktree` não muda (formato de `worktree:usage` igual).

### `pipe_maestro` (domínio)

- `PipeMaestro.RunnerTelemetry.Event`: `"claude_sessions_not_found" => "worktree"` em `@groups`.
- `PipeMaestro.RunnerTelemetry.record_log/2`: passa também
  `task_id: uuid(line["attrs"]["task_id"])` (a coluna `task_id` existe e não tem FK), para o
  evento apontar a tarefa como os eventos derivados do `job:finished`.
- Sem schema novo, sem migração.

### `pipe_maestro_web`

- `PipeMaestroWeb.RunnerLive.LogTab.kind_label/1`: `"claude_sessions_not_found"` →
  `"sessões do claude não encontradas"`. Nenhuma outra mudança de tela.

## Fronteiras

- O runner usa só `protocol` (`RunnerLog`, `Worktree`, `Job`) e a stdlib: nada de Ecto ou Phoenix.
- O domínio ganha só um rótulo de grupo e um campo lido do `attrs`; nada de web.
- O web só ganha um rótulo.

## Protocolo

- Toca `apps/pipe_maestro_protocol`: um valor novo na lista fechada `RunnerLog.events/0`.
- `docs/specs/protocolo-runner.md`: `claude_sessions_not_found` na lista de `event` do
  `runner:log`; em `worktree:usage`, `bytes` passa a dizer "o espaço dos worktrees e das sessões
  do CLI de cada um". Nenhum campo novo.
- **`protocol_version` não sobe.** O formato das mensagens é o mesmo; só o significado de
  `bytes` fica mais completo.
- **Runner antigo + control plane novo**: compatível; nunca manda o evento e manda `bytes` sem
  as sessões, como hoje.
- **Runner novo + control plane antigo**: compatível e degradado: `RunnerLog.parse/1` antigo
  descarta o `event` desconhecido e guarda a linha como log comum (warning); `bytes` maior é só
  um número.

## Telas

- Só o rótulo do evento em `PipeMaestroWeb.RunnerLive.LogTab` (aba de log do runner). Nenhum
  `data-testid` novo, nenhum componente Petal novo.
- e2e: rodar só `make e2e FILE=tests/runner-telemetry.spec.ts` uma vez, como confirmação de que
  a aba não quebrou; sem spec nova e sem screenshots (texto de rótulo apenas).

## Testes

**`apps/pipe_maestro_runner/test/pipe_maestro_runner/claude_sessions_test.exs`** (`async: true`,
`@moduletag :tmp_dir`, raiz sempre em `tmp_dir`):

- `dir_name/1`: `.`, `_`, espaço, `-` (`/a/b.c_d e` → `-a-b-c-d-e`); acentuado e emoji (`--`);
  caminho > 200 caracteres com sufixo de hash, contra um valor fixo calculado com a fórmula do
  CLI (registrado no teste).
- `real_path/1` e `task_cwd/2`: diretório temporário real + symlink para ele (o `/tmp` →
  `/private/tmp` do macOS sai naturalmente: em macOS o `tmp_dir` é resolvido; o teste cria o
  próprio link para valer também no Linux); `task_cwd` funciona com o worktree já apagado.
- `projects_root/1`: com `CLAUDE_CONFIG_DIR` no mapa, vazio e ausente (`~/.claude/projects`,
  só comparado como string, sem tocar disco); `project_dir_override?/1`.
- `remove/2`: raiz falsa com o diretório da tarefa (`UUID.jsonl` com `cwd` do worktree e de um
  subdiretório + `UUID/tool-results/x.txt` + `UUID/` sem `.jsonl` + `memory/`), outra tarefa,
  `...-<task_id>-x`, e um diretório "do dev". Depois: só os arquivos da tarefa sumiram, `memory/`
  ficou (diretório não sai), os outros intactos, bytes devolvidos = soma calculada antes.
  Sem `memory/`, o diretório do projeto sai.
- `remove/2` com `cwd` estranho num `.jsonl` → `{:error, :cwd_mismatch}` e nada apagado;
  diretório ausente → `:not_found`; só `UUID/` → `{:ok, bytes}`; override → `:shared_project_dir`.
- `mark/marked?/forget`.

**`disk_test.exs`**: worktree `t1` com sessão de N bytes na raiz falsa → `bytes` ≥ worktree + N;
depois de `ClaudeSessions.remove/2`, `bytes` cai pelo menos N.

**`job_runner_test.exs`** (bloco de `remove_worktree`, perto da linha 750; `claude_projects`
apontando para `tmp_dir`):

- job com `persist_session: true` (fake `CLAUDE_BIN`) cria o marcador; depois de criar à mão a
  sessão no diretório esperado, `remove_worktree` → `worktree:removed` sem `error`, sessão e
  marcador sumiram.
- tarefa marcada sem diretório de sessão → `worktree:removed` sem `error` e
  `capture_log` com `runner_event: claude_sessions_not_found` e os `event_attrs`
  (pelo `LogCollector`, como em `log_collector_test.exs` faz com `scratch_remove_failed`).
- tarefa sem marcador e sem sessão → sem evento.

**`apps/pipe_maestro_protocol`**: o teste de `RunnerLog` que lista eventos aceita o novo.
**`apps/pipe_maestro/test/pipe_maestro/runner_telemetry_test.exs`**: uma linha com
`event: "claude_sessions_not_found"` e `attrs.task_id` vira `%Event{kind: ..., task_id: ...}`,
no grupo `worktree`.
**`apps/pipe_maestro_web`**: teste de `kind_label/1` se houver o padrão; senão, coberto pela e2e.

## Documentação

- **ADR novo `docs/adr/0053-apagar-as-sessoes-do-cli-com-o-worktree.md`** (curto, referencia
  0041 e 0039): onde ficam as sessões (formato do CLI 2.1.319), as regras de segurança, o
  marcador e a heurística do evento, o `bytes` do `worktree:usage`, a limitação do segredo
  `CLAUDE_CONFIG_DIR`.
- **ADR 0041, Consequências**: a pendência vira "resolvida no ADR 0053: o runner apaga as
  sessões da tarefa quando remove o worktree".
- **ADR 0039**: `claude_sessions_not_found` na lista de eventos vindos do runner.
- **`docs/specs/protocolo-runner.md`**: como em "Protocolo".

## Riscos

- **Apagar o que não é da tarefa**: mitigado por nome exato, entradas só UUID, verificação do
  `cwd` e override tratado como compartilhado. Os testes cobrem prefixo igual e `memory/`.
- **Formato do CLI muda** (nome, raiz ou conteúdo): não apaga nada errado; o evento aparece.
- **Concorrência**: `remove_worktree` já recusa tarefa com job em execução ou na fila
  (`task_in_use?/2`); o job seguinte só recria a sessão depois. Duas remoções da mesma tarefa
  ao mesmo tempo: `File.rm_rf` idempotente; `bytes` pode contar duas vezes só no relato interno.
- **Custo**: ler `cwd` de `.jsonl` grandes (há um de 39 MB aqui) roda na task de remoção em
  segundo plano; `Disk.usage` só faz `lstat` (sem ler conteúdo) e já roda fora do processo.
- **Dados existentes**: tarefas antigas não têm marcador; são limpas sem evento. Órfãs de
  worktrees já removidos ficam (fora do escopo).
- **Testes nunca tocam o `~/.claude` real**: raiz por opção/argumento e `CLAUDE_CONFIG_DIR`
  temporário no `test_helper.exs`.
- **Dialyzer**: tipos de `reason` como átomos fechados; `real_path` com retorno `Path.t()`.
- **Cobertura**: módulo novo testado direto; o runner segue acima de 60%.

## Sugestão (fora do escopo)

Limpeza retroativa barata: ao iniciar, o runner lista `projects/` procurando nomes exatos
`dir_name(task_cwd(workdir, <uuid>))` cujo worktree não existe e aplica `remove/2`. Nesta
máquina sobram cerca de 15 diretórios assim.
