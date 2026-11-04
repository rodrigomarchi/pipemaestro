# 02 — Testes que falham: atualizar runner automaticamente

## O que foi escrito

### Protocolo — `apps/pipe_maestro_protocol/test/pipe_maestro_protocol/downloads_test.exs` (novo)
Contrato do diretório de binários (`PipeMaestroProtocol.Downloads`):
- `targets/0` → os quatro alvos, na ordem da tela;
- `binary_name/1` → `"pipemaestro_<alvo>"`; `checksums_name/0` → `"SHA256SUMS"`;
- `parse_checksums/1` → mapa nome → sha256 em hex minúsculo; aceita dois espaços ou ` *`
  (modo binário), ignora linha vazia, texto solto e hash com tamanho errado.

### Runner — servidor de downloads de teste
`apps/pipe_maestro_runner/test/support/download_server.exs` (carregado por
`test/test_helper.exs`): Bandit + Plug em 127.0.0.1, porta escolhida pelo sistema, que
serve `/downloads/runner/<arquivo>` de um diretório temporário, no padrão do
`Telemetry.Receiver`. `publish/4` grava o arquivo e o `SHA256SUMS`; `behave/3` define, por
arquivo, `:missing` (404) ou `:cut` (manda metade em chunked e mata a conexão);
`requests/1` conta as requisições (para provar que "não" não baixa nada).

### Runner — `self_update_test.exs` (novo), `PipeMaestroRunner.SelfUpdate`
- `target/2` (`:os.type/0` + `system_architecture`) → `{:ok, alvo}` ou
  `{:error, :unsupported_platform}`; `target/0` devolve um alvo de `Downloads.targets/0`.
- `urls/3` → `{:ok, %{binary:, checksums:}}`; com e sem `/` final; sem `download_url`
  usa `<plataforma>/downloads/runner/`. `{:error, :foreign_origin}` para outro host,
  `http` em host de https, outra porta, `http` para host não-loopback e host com sufixo
  (`pipemaestro.app.evil.com`).
- `install/2` (`opts`: `urls`, `target`, `progress`), com um "binário" que é um
  script `#!/bin/sh echo vNOVO`:
  - feliz: conteúdo novo, inode novo (rename), `0755`, executa e imprime `vNOVO`,
    nenhum temporário no diretório; o progresso chega a `100`;
  - checksum errado → `{:error, :checksum_mismatch}`; alvo fora do `SHA256SUMS` →
    `{:error, {:missing_checksum, nome}}`; 404 do binário ou do `SHA256SUMS` →
    `{:error, {:http_status, 404, url}}` (no 2º, só o `SHA256SUMS` foi pedido);
    conexão cortada no meio → `{:error, _}`. Em todos: binário antigo intacto, `0755`
    e nenhum `.update-*` sobrando;
  - diretório `0555` → `{:error, {:not_writable, dir}}`, mesmo inode, nada criado, nenhuma
    requisição (pulado se rodar como root).
- `clean_stale/1` apaga `.pipemaestro.update-*` e deixa o resto.
- `relaunch/3,4`: interativo roda o script de verdade com o mesmo argv e devolve o código
  de saída do filho (3); serviço chama o `halt` injetado com `0`; `child_env/1` lista
  `{nome, false}` exatamente para `__BURRITO_BIN_PATH`, `__BURRITO`, `RELEASE_*`,
  `ROOTDIR`, `BINDIR`, `EMU`, `PROGNAME` (não mexe em `HOME` e `PATH`).

### Runner — `update_test.exs` (novo), `Update.prompt/1` e `Update.handle/2`
`opts` de `handle/2`: `argv`, `auto_update`, `platform_url`, `env`, `tty?`, `gets`
(recebe o texto da pergunta, devolve a linha ou `:eof`), `relaunch`
(`fn bin, argv, mode -> ... end`). `handle/2` devolve o retorno de `relaunch` quando
atualiza, ou `{:fail, mensagem}`.
- `prompt/1` traz "Este runner está na versão X e a plataforma está na Y." e
  "Baixar e instalar a versão Y agora? [S/n]".
- Enter, `s`, `S`, `sim` → pergunta, troca o binário e chama `relaunch(bin, argv, :interactive)`
  com o argv exato (`["start", "--root", "/x"]`).
- `n`, `N`, `não`, `nao` e `:eof` (Ctrl+D) → `{:fail, Update.message(refusal)}`, nenhuma
  requisição, sem relaunch.
- Sem TTY e sem `--auto-update` → não chama `gets`, mensagem de hoje.
- `--auto-update` sem TTY → não pergunta, troca e usa o modo `:service`; com TTY →
  não pergunta e usa `:interactive`.
- Sem `__BURRITO_BIN_PATH` (Mix ou `RELEASE_ROOT`) → mensagem de hoje, mesmo com
  `--auto-update`.
- `download_url` de outra origem → `{:fail, msg}` contendo a mensagem de hoje, binário intacto.
- Download falho (404) → `{:fail, msg}` com o motivo ("404") e a mensagem de hoje.
- Sem escrita → `{:fail, msg}` com o diretório, `curl`, `SHA256SUMS`, `shasum -a 256 -c`,
  `chmod`, `mv` e sem `sudo` (pulado como root).

### Runner — testes existentes ajustados
- `service_test.exs`: `program/1` com Burrito devolve `[bin, "start", "--auto-update"]`;
  teste novo conferindo o argumento na plist e no `ExecStart` da unit.
- `main_test.exs`: o uso lista `--auto-update`.
- `test/mix/tasks/runner_tasks_test.exs`: `runner.start --auto-update` e
  `runner.login --auto-update` são aceitos (caem no erro seguinte, não em "Opção inválida").

### e2e — `e2e/tests/runner-connection.spec.ts` e `e2e/helpers/runnerProcess.ts`
- `RunnerProcess.write(text)` escreve no stdin do processo.
- Fluxo E (login e start): espera `Baixar e instalar a versão <controlPlane> agora? [S/n]`,
  responde `n`, confere código ≠ 0 e o texto de hoje. `@flow E` atualizado.
- A chave `config :pipe_maestro_runner, :update_prompt` em `config/e2e.exs` é
  implementação (etapa seguinte), por isso não entrou aqui.

## Falhas observadas (motivo certo)

`mix format` limpo. Comandos rodados a partir da raiz e de cada app.

**Protocolo** (`cd apps/pipe_maestro_protocol && mix test`): `73/76`, só os três novos falham:

```
** (UndefinedFunctionError) function PipeMaestroProtocol.Downloads.targets/0 is undefined (module PipeMaestroProtocol.Downloads is not available)
** (UndefinedFunctionError) function PipeMaestroProtocol.Downloads.binary_name/1 is undefined (module PipeMaestroProtocol.Downloads is not available)
** (UndefinedFunctionError) function PipeMaestroProtocol.Downloads.parse_checksums/1 is undefined (module PipeMaestroProtocol.Downloads is not available)
```
Esperado: o módulo ainda não existe.

**Runner** (`cd apps/pipe_maestro_runner && mix test`): `117/155`. As 38 falhas são
todas dos testes novos ou ajustados; todos os testes que já existiam continuam passando.

- `SelfUpdateTest` (17) e `UpdateTest` (17):
  ```
  ** (UndefinedFunctionError) function PipeMaestroRunner.SelfUpdate.target/0 is undefined (module PipeMaestroRunner.SelfUpdate is not available)
  ** (UndefinedFunctionError) function PipeMaestroRunner.SelfUpdate.urls/3 is undefined ...
  ** (UndefinedFunctionError) function PipeMaestroRunner.SelfUpdate.clean_stale/1 is undefined ...
  ** (UndefinedFunctionError) function PipeMaestroRunner.SelfUpdate.relaunch/3 is undefined ...
  ** (UndefinedFunctionError) function PipeMaestroRunner.SelfUpdate.child_env/1 is undefined ...
  ```
  Esperado: `SelfUpdate` não existe. Em `UpdateTest` o `setup` chama `SelfUpdate.target/0`,
  então a falha aparece ali antes de `Update.handle/2`/`prompt/1` (que também não existem).
- `ServiceTest` (2):
  ```
  left:  {["/opt/cp/pipemaestro", "start"], "/opt/cp"}
  right: {["/opt/cp/pipemaestro", "start", "--auto-update"], "/opt/cp"}
  ```
  e a plist ainda com `<string>start</string>\n  </array>`. Esperado: `program/1` ainda
  não passa `--auto-update`.
- `MainTest` "the usage lists --version and --auto-update": `assert usage =~ "--auto-update"`
  falha; o uso ainda não documenta a opção.
- `RunnerTasksTest` "start and login take --auto-update":
  ```
  expected: ~r/ainda não fez login/
  actual:   "Opção inválida: [{\"--auto-update\", nil}]"
  ```
  Esperado: `@switches` ainda não tem `auto_update`.

**e2e**: `make e2e.typecheck` passa (`tsc --noEmit`, código 0). O spec não foi rodado; sem a
implementação ele falha no `waitFor(updateQuestion)` do login desatualizado, porque o
runner sai com a mensagem de hoje sem perguntar ("Runner output never matched ...").

## Notas para a implementação
- `install/2` recebe `urls:` (de `urls/3`), `target:` e `progress:` (fun que recebe
  o percentual inteiro, chamada com `100` no fim). Os testes não passam `req_options`: o
  servidor é HTTP real em loopback.
- `handle/2` usa `SelfUpdate.target/0` por padrão (não há injeção de alvo nos testes).
- `relaunch/4` aceita `halt:` para o modo serviço; `relaunch/3` interativo devolve o
  código de saída do filho.
