# 02 — Testes que falham: versão do runner no formato AAAA-MM-DD.NN

Nenhum código de produção escrito. A única mudança fora de `test/` é em `config/test.exs`: uma
versão fixa do control plane (`config :claude_control_plane, ClaudeControlPlane.Version,
version: "2026-11-04.02"`), para que o selo "desatualizado" nos testes não dependa do estado git
do checkout.

## Testes criados ou alterados

### Protocolo (`apps/claude_control_plane_protocol`)

- `test/claude_control_plane_protocol/version_test.exs` (novo) — `ClaudeControlPlaneProtocol.Version`:
  - `format/2`: padding `.01`, `.12`, `.100`.
  - `parse_tag/1`: aceita `runner-AAAA-MM-DD.NN`; ignora `v1.2.3`, `runner-2026-11-04`,
    `runner-2026-11-04.1`, data inválida (`13-01`, `02-30`), `.00`, `-rc`, prefixo errado, sem prefixo.
  - `parse/1`: `{:release, date, n}`, `{:dev, {date, n}, sha}`, `{:dev, nil, sha}`, `:unknown`.
  - `next/2` (critério 1): primeiro do dia `.01`; incremento; lacuna (`.01,.03` → `.04`);
    virada de dia; `.09 → .10`, `.10 > .09`, `.99 → .100`; tags de outros formatos ignoradas.
  - `describe/3`: tag no HEAD; várias no HEAD (maior); `<base>+dev.<sha>`; `dev+<sha>`;
    sha nil → `dev+unknown`.
  - `compare/2`: data e depois NN.
  - `outdated?/2`: anterior marcado; igual/mais novo não; referência `X+dev` usa a base `X`;
    runner dev nunca; `0.1.0`/nil/"" não; referência sem release não marca ninguém.
- `test/claude_control_plane_protocol/version/git_test.exs` (novo, critério 2) —
  `ClaudeControlPlaneProtocol.Version.Git` num repositório git temporário (`git init` dentro do
  `tmp_dir`, commits e tags anotadas com `-c user.*`; nenhuma tag criada neste repositório):
  sem tag `runner-*` → `dev+<sha>`; tag no HEAD → a versão; commit após a tag →
  `<tag>+dev.<sha>`; tag de outro branch não alcançável não conta; `next/2` com as tags do dia
  e virada de dia; `CP_VERSION` sobrepõe; diretório fora de repositório (em `System.tmp_dir!`,
  porque o `tmp_dir` do ExUnit fica dentro deste checkout) → `dev+unknown`; `local_today/0`.
- `test/claude_control_plane_protocol_test.exs` — Hello aceita `2026-11-04.01`,
  `2026-11-04.12+dev.abc1234`, `dev+abc1234`, `0.1.0` e 120 bytes; recusa 121 (critério 4).
  **Já passa** hoje: é regressão, não comportamento novo.

### Runner (`apps/claude_control_plane_runner`)

- `test/claude_control_plane_runner/version_test.exs` (novo) — `ClaudeControlPlaneRunner.Version.version/0`
  no esquema (`parse != :unknown`); `__mix_recompile__?/0` é `false` logo após compilar.
- `test/claude_control_plane_runner/host_test.exs` — `Host.runner_version/0 == Version.version/0`,
  no formato `AAAA-MM-DD.NN(+dev.sha)?|dev+sha`; o Hello leva essa versão.
- `test/claude_control_plane_runner/main_test.exs` (novo, critério 3) — `Main.run(["--version"])`
  e `Main.run(["version"])` imprimem só `versão\n` e devolvem 0; o uso lista `cp-runner --version`.
- `test/claude_control_plane_runner/doctor_test.exs` — o doctor tem o item `versão` (`:ok`, detalhe
  = a versão).
- `test/mix/tasks/runner_tasks_test.exs` — `mix runner.version` imprime só a versão;
  `--next` imprime uma release; `start` (com credenciais e `--root` inexistente) imprime
  `cp-runner <versão>` como primeira mensagem antes de falhar; `status` (plataforma em
  `127.0.0.1:1`) mostra `Versão: <versão>`.

### Domínio (`apps/claude_control_plane`)

- `test/claude_control_plane/version_test.exs` (novo) — `ClaudeControlPlane.Version.build_version/0`
  (embutida, no esquema) e `__mix_recompile__?/0`; `version/0` devolve a configurada
  (`2026-11-04.02` em teste), senão a do build.
- `test/claude_control_plane/runners_test.exs` — `Runners.outdated?/2` (runner, referência)
  cobrindo antigo/igual/mais novo/dev/legado/nil/referência `+dev`/referência `dev+sha`;
  `Runners.outdated?/1` usa `ClaudeControlPlane.Version.version/0`.

### Web (`apps/claude_control_plane_web`, critério 5)

- `test/claude_control_plane_web/live/app_version_test.exs` (novo) — `app-version` com
  `2026-11-04.02` no layout público (`/login`), no do workspace e no do backoffice.
- `test/claude_control_plane_web/live/runners_live_test.exs` — `runner-version-<nome>` e
  `runner-outdated-<nome>` ("desatualizado"): presente para `2026-11-04.01`; ausente para igual,
  `+dev` e `0.1.0`.
- `test/claude_control_plane_web/live/runner_live_test.exs` — `runner-detail-version` e
  `runner-detail-outdated` na página do runner antigo; sem selo no atual.

Fora do ExUnit, como no plano: `make runner.release` (critério 6) e e2e/capturas (critério 7)
ficam para as etapas de implementação.

## Contrato que os testes fixam para a implementação

- `ClaudeControlPlaneProtocol.Version`: `format/2`, `parse_tag/1`, `parse/1`, `next/2`,
  `describe/3`, `compare/2`, `outdated?/2`.
- `ClaudeControlPlaneProtocol.Version.Git`: `current/1`, `next/2`, `local_today/0`.
- `ClaudeControlPlaneRunner.Version`: `version/0`, `__mix_recompile__?/0`; `Mix.Tasks.Runner.Version`.
- Item do doctor com nome `"versão"`; linha `Versão: ...` no status; primeira linha do start
  `cp-runner <versão>` (antes de validar `--root`).
- `ClaudeControlPlane.Version`: `build_version/0`, `version/0` (lê
  `Application.get_env(:claude_control_plane, ClaudeControlPlane.Version)[:version]`, senão o
  build), `__mix_recompile__?/0`.
- `Runners.outdated?/1` e `/2`.
- Test ids: `app-version`, `runner-version-<nome>`, `runner-outdated-<nome>`,
  `runner-detail-version`, `runner-detail-outdated`.

## Comandos e saída

Cada um a partir do diretório da app.

### Protocolo

```
mix test test/claude_control_plane_protocol/version_test.exs \
  test/claude_control_plane_protocol/version/git_test.exs \
  test/claude_control_plane_protocol_test.exs
```

```
  1) test compare/2 by date, then by the day's number (ClaudeControlPlaneProtocol.VersionTest)
     ** (UndefinedFunctionError) function ClaudeControlPlaneProtocol.Version.compare/2 is undefined (module ClaudeControlPlaneProtocol.Version is not available)
  ... (format/2, parse/1, parse_tag/1, next/2, describe/3, outdated?/2: o mesmo erro)
 22) test at a release tag, that release (ClaudeControlPlaneProtocol.Version.GitTest)
     ** (UndefinedFunctionError) function ClaudeControlPlaneProtocol.Version.Git.current/1 is undefined (module ClaudeControlPlaneProtocol.Version.Git is not available)
  ... (os demais de Git: current/1, next/2, local_today/0)
Result: 8/37 passed
Failed: 29 tests
```

O setup dos testes de Git (`git init`, commit, tags) roda: as falhas são só a ausência do módulo.
Os 8 que passam são os testes existentes do Hello mais a regressão de `runner_version`.

### Runner

```
mix test test/claude_control_plane_runner/host_test.exs \
  test/claude_control_plane_runner/main_test.exs \
  test/claude_control_plane_runner/version_test.exs \
  test/claude_control_plane_runner/doctor_test.exs \
  test/mix/tasks/runner_tasks_test.exs
```

```
  1) test it is recompiled only when the version it would compute changes (ClaudeControlPlaneRunner.VersionTest)
     ** (UndefinedFunctionError) function ClaudeControlPlaneRunner.Version.__mix_recompile__?/0 is undefined (module ClaudeControlPlaneRunner.Version is not available)
  2) test the version is embedded at build time in the release scheme (ClaudeControlPlaneRunner.VersionTest)
     ** (UndefinedFunctionError) function ClaudeControlPlaneRunner.Version.version/0 is undefined
  3) test the runner's version is its build's: ... (ClaudeControlPlaneRunner.HostTest)
     ** (UndefinedFunctionError) function ClaudeControlPlaneRunner.Version.version/0 is undefined
  4) test reports each check: ok, a warning or a problem, with what to do (ClaudeControlPlaneRunner.DoctorTest)
     ** (UndefinedFunctionError) function ClaudeControlPlaneRunner.Version.version/0 is undefined
  5) test the usage lists --version (ClaudeControlPlaneRunner.MainTest)
     Assertion with =~ failed
     code:  assert usage =~ "cp-runner --version"
     left:  "cp-runner login --url https://plataforma.exemplo.com\n    cp-runner start [--root ~/src]\n    cp-runner status | logout | doctor\n    cp-runner service print | install | uninstall\n"
  6) test --version and version print only the version and succeed (ClaudeControlPlaneRunner.MainTest)
     Assertion with == failed
     code:  assert Main.run([command]) == 0
     left:  2
  7) test version --next prints the next release, in the release scheme (Mix.Tasks.RunnerTasksTest)
     ** (UndefinedFunctionError) function Mix.Tasks.Runner.Version.run/1 is undefined (module Mix.Tasks.Runner.Version is not available)
  8) test start shows the version on its first line (Mix.Tasks.RunnerTasksTest)
     Assertion failed, no matching message after 0ms
     code: assert_received {:mix_shell, :info, [first]}
  9) test status shows the version (Mix.Tasks.RunnerTasksTest)
     ** (UndefinedFunctionError) function ClaudeControlPlaneRunner.Version.version/0 is undefined
 10) test version prints only the runner's version (Mix.Tasks.RunnerTasksTest)
     ** (UndefinedFunctionError) function Mix.Tasks.Runner.Version.run/1 is undefined
Result: 11/21 passed
Failed: 10 tests
```

(O teste do `status` chega a imprimir o resumo e recebe a desconexão da plataforma fora do ar; só
falha ao calcular a versão esperada.)

### Domínio

```
mix test test/claude_control_plane/version_test.exs test/claude_control_plane/runners_test.exs
```

```
  1) test the configured version, when there is one, takes the build's place (ClaudeControlPlane.VersionTest)
     ** (UndefinedFunctionError) function ClaudeControlPlane.Version.version/0 is undefined (module ClaudeControlPlane.Version is not available)
  2) test the build's version is embedded at compile time in the release scheme (ClaudeControlPlane.VersionTest)
     ** (UndefinedFunctionError) function ClaudeControlPlane.Version.build_version/0 is undefined (module ClaudeControlPlane.Version is not available)
  3) test runners a runner on a release older than the control plane's is outdated (ClaudeControlPlane.RunnersTest)
     ** (UndefinedFunctionError) function ClaudeControlPlane.Runners.outdated?/2 is undefined or private
  4) test runners by default, compared with this control plane's version (ClaudeControlPlane.RunnersTest)
     ** (UndefinedFunctionError) function ClaudeControlPlane.Runners.outdated?/1 is undefined or private
Result: 13/17 passed
Failed: 4 tests
```

### Web

```
mix test test/claude_control_plane_web/live/app_version_test.exs \
  test/claude_control_plane_web/live/runners_live_test.exs \
  test/claude_control_plane_web/live/runner_live_test.exs
```

```
  1) test the backoffice layout shows it in the sidebar's footer (ClaudeControlPlaneWeb.AppVersionTest)
     code: assert has_element?(view, "[data-testid=app-version]", @version)
  2) test the workspace layout shows it in the sidebar's footer (ClaudeControlPlaneWeb.AppVersionTest)
     code: assert has_element?(view, "[data-testid=app-version]", @version)
  3) test the public layout shows the control plane's version (ClaudeControlPlaneWeb.AppVersionTest)
     code: assert has_element?(view, "[data-testid=app-version]", @version)
  4) test shows the runner's version, marked when older than the control plane's (ClaudeControlPlaneWeb.RunnerLiveTest)
     code: assert has_element?(view, "[data-testid=runner-detail-version]", "2026-11-04.01")
  5) test shows each runner's version and marks the ones older than the control plane (ClaudeControlPlaneWeb.RunnersLiveTest)
     code: assert has_element?(view, "[data-testid=runner-version-antigo]", "2026-11-04.01")
Result: 15/20 passed
Failed: 5 tests
```

Todas as falhas são pela ausência do comportamento (módulo/função inexistente, elemento sem
`data-testid`, comando não reconhecido), não por sintaxe ou setup. `mix format` aplicado.

## Notas para a implementação

- As chamadas a módulos que ainda não existem geram avisos de compilação nos testes; somem quando
  os módulos existirem (`make ci` usa `--warnings-as-errors`).
- Os testes de `Version.Git` alteram `CP_VERSION` (global) e por isso são `async: false`.
- O teste de `__mix_recompile__?/0` presume que o valor calculado no teste é o mesmo da
  compilação (mesmo HEAD, mesmo `CP_VERSION`), o que vale para `mix test`, que recompila antes.
