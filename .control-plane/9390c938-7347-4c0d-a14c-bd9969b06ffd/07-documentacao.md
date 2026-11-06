# 07 — Documentação e resumo para revisão

## O que mudou e por quê
A versão do runner era a do `HEAD`: qualquer commit (tela, migração, texto) recusava
todos os runners. Agora o runner tem versão própria, a do último commit que mudou o
que entra no binário dele. O control plane continua com a versão do `HEAD`.

- **`pipe_maestro_protocol`**: `Version.Git.runner_paths/0` e `runner/1`; override
  `RUNNER_VERSION`; `CP_VERSION` vale só para o control plane.
- **`pipe_maestro`**: `Version.runner_version/0`; `Runners.version_check/1` e
  `outdated?/1` comparam com ela (igualdade exata).
- **`pipe_maestro_runner`**: `Version` usa `Git.runner/1`; mensagens de `Update` dizem
  "a plataforma pede a versão X do runner".
- **`pipe_maestro_web`**: `RunnersLive`/`RunnerComponents` mostram a versão de runner
  esperada (`data-testid="runners-expected-version"`); `/version` ganha `runner_version`.
- **Raiz/infra**: `mix.exs`, `Makefile` (`runner.version`, `cp.version`), `Dockerfile`,
  `scripts/build_runner_binaries.sh` e `scripts/deploy.sh` (só reconstrói os binários
  quando o `VERSION` publicado difere da versão de runner do commit).

## Protocolo
O formato não mudou e `protocol_version` não subiu. Muda só a semântica de `"version"`
no payload `outdated`: passa a ser a versão do runner exigida. **Runner antigo**:
anuncia `dev+<HEAD antigo>`, diferente da nova, então é recusado uma última vez com o
payload de sempre e se atualiza pelo fluxo da ADR 0025 (ou vê a mensagem e o link).
Dali em diante, deploys que não tocam o runner não o recusam.

## Riscos e onde olhar
- **Lista de caminhos** (`Git.runner_paths/0`): algo que muda o binário fora dela deixa
  runner velho conectar. É conservadora de propósito; confira se falta algum caminho.
- **Clone raso ou Docker sem `.git`**: sem `RUNNER_VERSION` o resultado é `dev+unknown`
  e todo runner é recusado. `make image` passa as duas versões.
- **Primeiro deploy** depois do merge gera os binários (ainda não há `VERSION`).
- `scripts/deploy.sh` só roda no servidor: verificado com `bash -n`; `shellcheck` não
  estava instalado.
- Quebra de contrato continua exigindo subir `protocol_version`.

## Como verificar
- `make ci > /tmp/ci.log 2>&1; echo $?`
- `make e2e FILE=tests/runner-connection.spec.ts` e `make e2e.shots`
- `make -s runner.version` e `make -s cp.version`: um commit só na web muda a segunda e
  mantém a primeira.
- Na tela: Executores → "Conectar um runner" mostra o selo com a versão de runner
  esperada (claro e escuro); o rodapé segue com a versão da plataforma.
- No deploy sem mudança no runner, o log diz `Runner <v> already published ... not rebuilt`.

## ADRs e docs
- Nova: `docs/adr/0035-versao-propria-do-runner.md`, no índice de `docs/README.md`.
- Status ajustado em `docs/adr/0016-esquema-de-versao.md`,
  `docs/adr/0020-binarios-do-runner-no-deploy.md` e
  `docs/adr/0023-runner-na-versao-da-plataforma.md`.
- `docs/specs/protocolo-runner.md`, `docs/guias/deploy.md`, `docs/guias/instalacao.md`.
