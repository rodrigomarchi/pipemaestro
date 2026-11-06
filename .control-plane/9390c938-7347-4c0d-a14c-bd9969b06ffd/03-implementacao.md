# 03 — Implementação: versão própria do runner

O plano (`01-plano.md`) foi implementado. Os testes da etapa 02 passam sem mudança, e
nenhum deles foi enfraquecido. Um só teste antigo foi ajustado, explicado abaixo.

## O que mudou, por app

### `pipe_maestro_protocol`
- `PipeMaestroProtocol.Version.Git`:
  - `runner_paths/0`: a lista dos caminhos que entram no binário do runner. São eles:
    `apps/pipe_maestro_runner`, `apps/pipe_maestro_protocol`, `config`, `mix.exs`,
    `mix.lock`, `.tool-versions`, `docker/runner-binary` e
    `scripts/build_runner_binaries.sh`.
  - `runner/1`: aplica o mesmo `Version.describe/3` ao commit
    `git log -1 --format=%h -- <caminhos>`, a partir da raiz do repositório
    (`rev-parse --show-toplevel`). Usa as tags desse commit e as alcançáveis dele.
    `RUNNER_VERSION`, quando definida e não vazia, é usada como está. Sem repositório,
    ou sem nenhum commit nos caminhos, o resultado é `dev+unknown`.
  - `CP_VERSION` vale só para `current/1`.
- O formato das mensagens não mudou, e `protocol_version` continua o mesmo.

### `pipe_maestro` (domínio)
- `PipeMaestro.Version`: novas `runner_version/0` (o valor configurado, senão o da
  compilação) e `build_runner_version/0`. `__mix_recompile__?/0` agora considera as
  duas versões.
- `Runners.version_check/1` e `outdated?/1` comparam com `Version.runner_version/0`.

### `pipe_maestro_runner`
- `PipeMaestroRunner.Version` agora usa `Git.runner(__DIR__)`.
- `PipeMaestroRunner.Update`: a recusa e a pergunta dizem "a plataforma pede a versão X
  do runner".
- **Teste ajustado:** `device_login_test.exs` conferia o texto antigo
  (`"na 2026-11-04.02"`), que a etapa 02 decidiu trocar. Ele agora confere
  `"pede a versão 2026-11-04.02 do runner"`. O nome do teste também foi encurtado, para
  passar no `mix format`.

### `pipe_maestro_web`
- `RunnersLive`: o assign `runner_version` substitui `version` nos downloads e no modal.
- `RunnerComponents`: os downloads dizem "a que esta plataforma pede". O
  `connect_instructions` mostra, nos dois casos (com e sem binários publicados), um
  `<.badge>` Petal com `data-testid="runners-expected-version"`. O attr `version` ficou
  obrigatório.
- `HealthController` (`/version`): acrescenta a chave `runner_version`.
- O rodapé continua mostrando a versão do control plane.

### Raiz e infra
- `mix.exs` (`binary_version/0`): usa `RUNNER_VERSION` quando definida, senão a release
  ou o commit, como antes. Dentro do contêiner de build não há `.git`, e é a variável
  que chega lá.
- `scripts/build_runner_binaries.sh`: troca `CP_VERSION` por `RUNNER_VERSION`.
- `scripts/deploy.sh`, passo 4: a função `runner_published` compara o
  `${DOWNLOADS_DIR}/runner/VERSION` com a versão de runner do commit. Se forem iguais,
  os binários não são gerados de novo. Senão, o script gera os binários, grava `VERSION`
  no diretório de staging e publica.
- `Makefile`: `runner.version` imprime a versão do runner, e o novo `cp.version` imprime
  a do control plane. `image` passa as duas como `--build-arg`.
- `Dockerfile`: `ARG/ENV RUNNER_VERSION`.
- e2e: `playwright.config.ts` passa `RUNNER_VERSION=${versions.runner}` ao servidor.
  `runnerProcess.ts` usa `versions.runner` por padrão e o envia como `RUNNER_VERSION`.

### Documentação
- A ADR nova é a `docs/adr/0035-versao-propria-do-runner.md`. O status das ADRs 0016,
  0020 e 0023 aponta para ela, e o índice está em `docs/README.md`.
- `docs/specs/protocolo-runner.md`: `"version"` do `outdated` agora é a versão de runner
  exigida, e um deploy que não muda o runner não recusa ninguém.
- `docs/guias/deploy.md`: os binários só são gerados quando a versão do runner muda, e o
  `VERSION` fica publicado.
- `docs/guias/instalacao.md`: os dois build args da imagem.

## Runner antigo
Não há mudança de formato. Um runner antigo anuncia `dev+<HEAD antigo>`, que é
diferente da versão de runner nova. Por isso é recusado uma última vez, com o payload de
sempre, e se atualiza pelo fluxo da ADR 0025. O teste de recusa no canal e no device
code (`runner_version_test.exs`) cobre isso.

## Como verificar
- `make ci.quick > /tmp/ciq.log 2>&1; echo $?` → **0**.
- `make e2e` → **exit 0**, 23 testes passaram (`runner-connection.spec.ts` incluído). `make e2e.shots` → exit 0. As telas `runner-connection/.../05-runner-connect-downloads{,-dark}.png` foram conferidas: o selo com a versão de runner esperada aparece no modal, o rodapé mostra a versão do control plane, e as duas variantes, clara e escura, estão legíveis.
- No checkout: `make -s cp.version` deu `dev+311c483` (o `HEAD` daquele momento), e
  `make -s runner.version` deu `dev+41e7bcd` (o último commit no runner). Um commit só
  na web muda a primeira versão e mantém a segunda.
- Deploy (critério 5): o `scripts/deploy.sh` roda só no servidor, então a verificação é
  manual. Num deploy sem mudança no runner, o log mostra
  `Runner <v> already published ... not rebuilt`. O primeiro deploy depois desta
  mudança gera os binários, porque ainda não existe `VERSION` publicado. O
  `shellcheck` não está instalado nesta máquina, então foi rodado `bash -n` nos dois
  scripts, e deu ok.
