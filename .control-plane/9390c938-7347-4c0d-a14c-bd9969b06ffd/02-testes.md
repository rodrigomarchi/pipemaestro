# 02 — Testes que falham: versão própria do runner

Testes escritos antes da implementação, seguindo o plano (`01-plano.md`). Nenhum
código de produção foi alterado. A única mudança fora de `test/` e de `e2e/` é
`config/test.exs`, que fixa a versão de runner exigida
(`runner_version: "2026-11-03.02"`), **diferente** da do control plane
(`version: "2026-11-04.02"`). Isso faz os testes distinguirem as duas, como acontece
num deploy que não mexe no runner.

## O que cada teste descreve

### `pipe_maestro_protocol`: `test/pipe_maestro_protocol/version/git_test.exs`
Um repositório git temporário, com commits em caminhos reais. Os testes novos ficam no `describe "the runner's version"`:
- `runner_paths/0` inclui `apps/pipe_maestro_runner`, `apps/pipe_maestro_protocol`,
  `config`, `mix.exs`, `mix.lock`, `.tool-versions`, `docker/runner-binary` e
  `scripts/build_runner_binaries.sh`, e não inclui `apps/pipe_maestro`,
  `apps/pipe_maestro_web`, `docs` nem `e2e`.
- Critério 1: depois de um commit no runner, commits em web, domínio, docs ou e2e
  mantêm `Git.runner/1` e mudam `Git.current/1`.
- Critério 2: um commit em cada caminho do runner muda a versão do runner.
- O cálculo parte da raiz do repositório, qualquer que seja o subdiretório.
- Tag `runner-*` no commit do runner → a release. Tag só num commit posterior
  (de web) → `<tag alcançável>+dev.<commit do runner>`.
- Se `RUNNER_VERSION` estiver definida, ela é usada como está. Vazia, é ignorada.
  `CP_VERSION` vale só para `current/1`.
- Fora de um repositório, o resultado é `dev+unknown`.

### `pipe_maestro` (domínio)
- `version_test.exs`: `build_runner_version/0` segue o esquema e é igual a
  `Git.runner(__DIR__)`. `runner_version/0` usa o valor configurado, diferente de `version/0`.
- `runners/version_check_test.exs`: critério 3. A versão de runner exigida é aceita;
  qualquer outra é recusada com `{:outdated, "2026-11-03.02"}`, inclusive a do
  control plane. `outdated?/1` compara com a versão de runner exigida.
- `runners_test.exs`: `outdated?/1` usa por padrão a versão de runner exigida.

### `pipe_maestro_web`
- `channels/runner_version_test.exs`: critério 4. `"version"` no join e no `409` do
  device code é a versão de runner exigida. Um runner na versão do control plane é
  recusado.
- `controllers/page_controller_test.exs` (HealthController): `/version` traz
  `runner_version`.
- `live/runners_live_test.exs`: critério 7. `runner-download-version` mostra a versão
  do runner, não a do control plane. O modal "Conectar runner" tem
  `runners-expected-version`. O selo "desatualizado" compara com a versão de runner
  exigida: um runner em `2026-11-04.01`, mais antigo que o control plane mas não que
  o runner, não aparece como desatualizado.
- `live/runner_live_test.exs`: o selo da página do runner segue a mesma regra.

### `pipe_maestro_runner`
- `version_test.exs`: `Version.version/0 == Git.runner(__DIR__)`. `runner_paths/0`
  cobre o próprio app e cada app do umbrella de que ele depende (`in_umbrella` no
  `mix.exs`), a mitigação do risco "caminhos esquecidos".
- `update_test.exs`: `prompt/1` e `message/1` dizem "a plataforma pede a versão X do
  runner" e não dizem mais "a plataforma está na".

### e2e: `e2e/tests/runner-connection.spec.ts`
- `e2e/helpers/env.ts`: `versions.runner = "2026-11-03.02"` (diferente de
  `controlPlane`) e `outdatedRunner = "2026-11-03.01"`.
- `e2e/pages/RunnersPage.ts`: getter `expectedVersion` (`runners-expected-version`).
- Fluxos B e E: o runner usa `versions.runner`. A pergunta e a recusa trazem o texto
  novo. A lista e a página do runner mostram `versions.runner`. O rodapé continua com
  `versions.controlPlane`. O modal mostra a versão esperada.
- **A implementação precisa ajustar** `e2e/playwright.config.ts` (`RUNNER_VERSION`
  no servidor) e `e2e/helpers/runnerProcess.ts` (padrão `versions.runner`, enviado
  como `RUNNER_VERSION`). Isso é ligação da infra com o código novo, e por isso ficou
  para a etapa de implementação.

## Execução: falham pelo motivo certo

`mix format`: ok. `mix test` (raiz): **só** os testes novos ou ajustados falham.
O restante passa.

```
protocol:  Result: 77/87 passed   Failed: 10 tests
domínio:   Result: 319/325 passed Failed: 6 tests
web:       Result: 314/323 passed Failed: 9 tests
runner:    Result: 186/190 passed Failed: 4 tests
```

Trechos e por que cada falha é a esperada:

- **protocol (10)**: a função ainda não existe.
  ```
  ** (UndefinedFunctionError) function PipeMaestroProtocol.Version.Git.runner/1 is undefined or private
  ** (UndefinedFunctionError) function PipeMaestroProtocol.Version.Git.runner_paths/0 is undefined or private
  ```
- **domínio, `VersionTest` (2)**: as funções ainda não existem.
  ```
  ** (UndefinedFunctionError) function PipeMaestro.Version.build_runner_version/0 is undefined or private
  ** (UndefinedFunctionError) function PipeMaestro.Version.runner_version/0 is undefined or private
  ```
- **domínio, `version_check` (4 testes, entre `VersionCheckTest` e `RunnersTest`)**: o código ainda compara com a versão do control plane.
  ```
  code:  assert Runners.version_check(@runner_version) == :ok
  left:  {:outdated, "2026-11-04.02"}
  code:  assert Runners.version_check(@control_plane) == {:outdated, @runner_version}
  left:  :ok
  code: refute Runners.outdated?(%Runner{runner_version: @runner_version})
  ```
- **web, canal e device (4)**: o código aceita e recusa pela versão do control plane.
  ```
  test a runner on the current version joins → right: {:error, ...}
  test a runner on the control plane's version is refused → right: {:ok, ...}
  test an outdated runner cannot even sign in → expected response with status 409, got: 200
  test a runner on another version is refused → refusal["version"] == "2026-11-04.02"
  ```
- **web, `/version` (1)**: falta a chave `runner_version`.
  ```
  right: %{"release" => "0.1.0", "version" => "2026-11-04.02"}
  ```
- **web, telas (4)**: `runner_version/0` não existe, e o selo ainda compara com a versão do control plane.
  ```
  ** (UndefinedFunctionError) function PipeMaestro.Version.runner_version/0 is undefined or private
  code: refute has_element?(view, "[data-testid=runner-outdated-atual]")
  code: refute has_element?(view, "[data-testid=runner-detail-outdated]")
  ```
- **runner (4)**: `Git.runner/1` e `runner_paths/0` não existem, e os textos ainda são os antigos.
  ```
  ** (UndefinedFunctionError) function PipeMaestroProtocol.Version.Git.runner/1 is undefined or private
  left:  "Este runner está na versão dev+abc1234 e a plataforma está na dev+def5678.\n..."
  right: "Este runner está na versão dev+abc1234 e a plataforma pede a versão dev+def5678 do runner."
  ```

Nenhuma falha vem de erro de sintaxe, de compilação ou de setup.

`make e2e.typecheck`: **passa** (exit 0). O spec compila. Rodado, ele falharia porque:
o servidor ainda exige a versão do control plane; o runner ainda anuncia `CP_VERSION`;
os textos são os antigos; e `runners-expected-version` não existe. A suíte e2e não foi rodada nesta etapa.

## Fora do ExUnit
- Critério 5 (`scripts/deploy.sh` pula o rebuild): segue o plano, com verificação
  manual descrita no PR e `shellcheck`. Nenhum teste automatizado.
- Critério 6 (`make runner.version`): coberto indiretamente. `runner_tasks_test.exs`
  já confere que `runner.version` imprime `PipeMaestroRunner.Version.version()`, que
  passa a ser `Git.runner/1`.
