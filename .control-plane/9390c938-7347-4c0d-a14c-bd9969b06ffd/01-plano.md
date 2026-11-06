# 01 — Entendimento e plano: versão própria do runner

## Diagnóstico

Hoje a versão do runner e a do control plane são **a mesma string**, calculada do
`HEAD` do checkout:

- `PipeMaestroProtocol.Version.Git.current/1` (`apps/pipe_maestro_protocol/lib/pipe_maestro_protocol/version/git.ex`)
  devolve a tag `runner-*` do `HEAD` ou `dev+<commit do HEAD>`. É usada por
  `PipeMaestro.Version` (`apps/pipe_maestro/lib/pipe_maestro/version.ex`) e por
  `PipeMaestroRunner.Version` (`apps/pipe_maestro_runner/lib/pipe_maestro_runner/version.ex`).
- `PipeMaestro.Runners.version_check/1` (`apps/pipe_maestro/lib/pipe_maestro/runners.ex`)
  exige `runner_version == PipeMaestro.Version.version()` (ADR 0023).
- `scripts/deploy.sh` (passo 4) reconstrói os quatro binários Burrito em todo deploy,
  com `CP_VERSION=$(mix runner.version)`, ou seja, de novo o commit do `HEAD`.

Resultado: qualquer commit — uma tela, uma migração, um texto da landing — muda a
versão, e todo runner é recusado e precisa se atualizar, mesmo que o binário novo seja
byte a byte o mesmo código. A ADR 0023 já registrava isso como consequência aceita
("Todo deploy exige atualizar os runners"); a tarefa pede para desfazer esse custo.

### Como a comunidade do Burrito lida com isso

O Burrito não tem mecanismo de atualização nem de versão de compatibilidade: ele só
empacota a release (e descompacta um payload por versão). Os projetos que o usam
(CLIs e agentes distribuídos como binário único) versionam o binário **independente**
do servidor, publicam releases só quando o binário muda, e o servidor decide quem
aceita por um contrato de compatibilidade — versão de protocolo ou "versão mínima" —
nunca pelo commit do servidor. O PipeMaestro já tem o contrato (`protocol_version`,
`supported_versions/0`); o que falta é o runner ter uma identidade que só mude quando
o **build do runner** muda.

## Decisão proposta

**A versão do runner passa a ser a do último commit que mudou o que entra no binário
do runner**, não a do `HEAD`.

- "O que entra no binário" é uma lista fixa de caminhos, no `protocol`
  (`PipeMaestroProtocol.Version.Git.runner_paths/0`):
  `apps/pipe_maestro_runner`, `apps/pipe_maestro_protocol`, `config/`, `mix.exs`,
  `mix.lock`, `.tool-versions`, `docker/runner-binary/`,
  `scripts/build_runner_binaries.sh`. É conservadora de propósito: na dúvida, um
  caminho entra (o custo é uma atualização a mais; o contrário é um runner velho
  conectando).
- O cálculo reusa o esquema da ADR 0016 aplicado a esse commit `R =
  git log -1 --format=%h -- <caminhos>`: tag `runner-*` em `R` → a tag; senão
  `<maior tag alcançável de R>+dev.<R>`; senão `dev+<R>`; sem git → `dev+unknown`.
  Formato e `PipeMaestroProtocol.Version.parse/1` não mudam.
- O control plane continua com a própria versão (`HEAD`), que aparece no rodapé e no
  `/version`, e ganha **a versão de runner que ele exige**
  (`PipeMaestro.Version.runner_version/0`), calculada do mesmo checkout na compilação.
  `version_check/1` compara com ela, **igualdade exata**, como na ADR 0023.
- O deploy compara a versão de runner do commit com a publicada
  (`/var/www/pipemaestro/downloads/runner/VERSION`) e **só reconstrói os binários
  quando ela muda**: deploy mais rápido e binários estáveis.

Alternativa descartada (vai na ADR): "versão mínima" ou janela de compatibilidade por
ordem de versão. Em produção as versões são `dev+<commit>`, sem ordem (ADR 0023), e
afrouxar a igualdade reabre o risco de runner velho rodando que motivou a ADR 0023.

## Entendimento — o que muda para quem usa

- Um deploy que não mexe no runner (web, domínio, telas, migrações) **não pede
  atualização**: os runners reconectam quando o control plane reinicia e voltam
  online sozinhos.
- Um deploy que mexe no runner continua pedindo a atualização, com o fluxo da ADR 0025
  (Enter no terminal; automático no serviço com `--auto-update`).
- A mensagem do runner deixa de dizer "a plataforma está na X" (X era a versão do
  control plane) e passa a dizer qual versão **do runner** a plataforma pede.
- A tela de runners mostra a versão do runner que a plataforma espera.

### Critérios de aceite verificáveis

1. Dois commits em que o segundo só muda `apps/pipe_maestro_web/**` (ou
   `apps/pipe_maestro/**`, `docs/**`, `e2e/**`) produzem **a mesma** versão de runner
   e versões diferentes de control plane.
2. Um commit que muda `apps/pipe_maestro_runner/**`, `apps/pipe_maestro_protocol/**`,
   `mix.lock`, `config/**`, `.tool-versions` ou `docker/runner-binary/**` muda a versão
   de runner.
3. `Runners.version_check/1` aceita o runner na `PipeMaestro.Version.runner_version/0`
   e recusa qualquer outra (inclusive a versão do control plane, quando difere).
4. O payload de recusa (`409` do device code e join do canal) traz em `"version"` a
   versão de runner exigida.
5. `scripts/deploy.sh` não reconstrói os binários quando o `VERSION` publicado é igual
   à versão de runner do commit, e grava `VERSION` quando reconstrói.
6. `make runner.version` imprime a versão do runner; a do control plane continua
   acessível (`/version`, rodapé).
7. A tela de runners mostra a versão de runner esperada (`data-testid`), clara e escura.
8. `make ci` e `make e2e` verdes.

## Mudanças por app

### `pipe_maestro_protocol`
- `PipeMaestroProtocol.Version.Git`:
  - `runner_paths/0` (a lista acima) e `runner(dir)`: a versão do runner, pelo commit
    `R` do `git log -1 -- <caminhos>` (com `-C` na raiz do repositório:
    `git rev-parse --show-toplevel`), mesmo `Version.describe/3` com tags em `R` e
    alcançáveis de `R`.
  - Override por ambiente: `RUNNER_VERSION`, quando definida e não vazia, é usada como
    está (Docker, build dos binários no contêiner, e2e). `CP_VERSION` passa a valer só
    para o control plane.
- `PipeMaestroProtocol.Version`: sem mudança de formato. Funções puras continuam as
  mesmas; se o recorte por caminho exigir, um helper puro para montar a versão a partir
  de `R`.
- **Sem mudança no formato das mensagens.**

### `pipe_maestro_runner`
- `PipeMaestroRunner.Version`: `@version Git.runner(__DIR__)` e
  `__mix_recompile__?/0` comparando com `Git.runner/1`.
- `Mix.Tasks.Runner.Version` / `Commands.Version`: imprimem a versão do runner (é o que
  já mostram; o valor muda de origem). `--next` não muda (tags são globais).
- `PipeMaestroRunner.Update`: textos de recusa passam a dizer "a plataforma pede a
  versão X do runner" em vez de "a plataforma está na X". Lógica de atualização
  (ADR 0025) não muda.

### `pipe_maestro` (domínio)
- `PipeMaestro.Version`: `runner_version/0` (configurada em
  `config :pipe_maestro, PipeMaestro.Version, runner_version: …`, senão a da
  compilação, `Git.runner(__DIR__)`), `__mix_recompile__?/0` considerando as duas.
- `PipeMaestro.Runners.version_check/1` compara com `Version.runner_version/0`;
  `outdated?/1,2` usa a mesma referência por padrão.
- Sem schema nem migração.

### `pipe_maestro_web`
- `RunnerChannel` e `RunnerDeviceController`: sem mudança de lógica (já repassam o
  `expected` do `version_check/1`); docs dos módulos e de `RunnerUpdate` ajustados.
- `RunnersLive`: assign `runner_version: Version.runner_version()` e exibição dela
  junto aos downloads / modal "Conectar runner".
- `HealthController` (`/version`): acrescenta `runner_version` ao JSON (aditivo).

### Raiz / infra
- `mix.exs` (`binary_version/0`): a parte "release ou commit" usa a versão do runner
  (lê `RUNNER_VERSION` ou o mesmo commit `R`), para o payload do Burrito também só
  mudar quando o runner muda (mantém o instante do build).
- `scripts/deploy.sh`: `RUNNER_VERSION=$(make -s runner.version)`; pula o passo 4 se
  `${DOWNLOADS_DIR}/runner/VERSION` for igual; senão passa `RUNNER_VERSION` ao
  `scripts/build_runner_binaries.sh` e grava `VERSION` no diretório publicado.
- `scripts/build_runner_binaries.sh`: usa `RUNNER_VERSION` no lugar de `CP_VERSION`.
- `Makefile`: `runner.version` passa a ser a do runner; novo `cp.version` (ou similar)
  para a do control plane; `image` passa as duas (`--build-arg CP_VERSION`,
  `--build-arg RUNNER_VERSION`), e o `Dockerfile` recebe o `ARG/ENV RUNNER_VERSION`.
- `config/test.exs`: fixa `runner_version` junto do `version`. e2e: fixa
  `RUNNER_VERSION` para o servidor e o runner (helpers em `e2e/helpers/env`).

## Fronteiras

- O cálculo fica no `protocol`, a única app compartilhada; o runner continua
  dependendo só do `protocol`; o domínio não ganha nada de web. Nenhuma regra de
  dependência muda.

## Protocolo

- **Não toca o formato.** `Hello.runner_version` continua string de 1 a 120 bytes;
  `protocol_version` **não sobe** (continua 4); o payload `"outdated"` mantém as
  chaves `reason`, `version`, `runner_version`, `download_url`.
- **Muda a semântica documentada** de `"version"` no payload: de "versão do control
  plane" para "versão do runner que a plataforma exige". `docs/specs/protocolo-runner.md`
  (seções do login/`409` e do join) é atualizado, assim como a frase "O deploy publica
  o runner do mesmo commit".
- **Runner antigo:** compatível com o fluxo existente. Ele anuncia `dev+<HEAD antigo>`,
  que difere da versão de runner nova, então é recusado **uma última vez** com o mesmo
  payload de hoje: com a ADR 0025 ele se atualiza (Enter / serviço), sem ela mostra a
  mensagem e o link como antes. O binário baixado já tem a versão nova; dali em diante,
  deploys que não tocam o runner não o recusam mais. O texto antigo do runner dirá "a
  plataforma está na X" com X = versão do runner, um detalhe cosmético só nessa
  transição.

## Telas

- `RunnersLive` (lista de runners): a versão de runner esperada, perto dos links de
  download e no modal "Conectar runner". Componente Petal: `<.badge>` ou texto
  `<.p>`/`<.h5>` conforme `docs/guias/ui-petal.md` (conferir attrs reais).
  `data-testid="runners-expected-version"`.
- O rodapé (`Layouts`) continua com a versão do control plane.
- Playwright: `e2e/tests/runner-connection.spec.ts` (fluxos B e E) — o B confere o
  `runners-expected-version`; o E passa a usar `versions.runner` e o texto novo da
  recusa. `make e2e.shots` claro e escuro.

## Testes

- `apps/pipe_maestro_protocol/test/pipe_maestro_protocol/version_test.exs` +
  teste novo de `Version.Git` com um repositório git temporário: commit só fora dos
  caminhos mantém a versão do runner e muda a do `HEAD` (critério 1); commit em
  cada tipo de caminho muda (critério 2); tag em `R`; `RUNNER_VERSION` override;
  sem git → `dev+unknown`.
- `apps/pipe_maestro/test/pipe_maestro/version_test.exs`: `runner_version/0`
  configurada e da compilação.
- `apps/pipe_maestro/test/pipe_maestro/runners/version_check_test.exs`: aceita a
  versão de runner, recusa a do control plane quando difere (critério 3).
- Web: testes do canal / device controller conferindo `"version"` = versão de runner
  (critério 4); `runners_live_test.exs` com o `data-testid` (critério 7);
  health controller com `runner_version`.
- Runner: `version_test.exs`, `update` (texto novo), `runner_tasks_test.exs`.
- Deploy (critério 5): o skip vira uma função de shell pequena; verificação manual
  descrita no PR (o script roda só no servidor), mais `shellcheck` se disponível.
- e2e: `runner-connection.spec.ts`.

## Documentação

- **ADR nova** `docs/adr/0035-versao-propria-do-runner.md`: versão do runner pelo
  último commit dos caminhos do runner; supera em parte a ADR 0023 (igualdade com a
  versão do runner exigida, não com a do control plane) e ajusta a 0016 (duas
  versões, mesma série/formato) e a 0020 (binários só reconstruídos quando a versão
  muda). Alternativa descartada: versão mínima/janela. Atualizar o "Status" das
  ADRs afetadas com um apontamento para a 0035 e o índice das ADRs.
- `docs/specs/protocolo-runner.md` (semântica do `"version"` do `outdated`).
- `docs/guias/deploy.md` (binários só quando o runner muda; `VERSION` publicado).
- Roadmap em `docs/plano/` se listar a pendência.

## Riscos

- **Caminhos esquecidos**: algo que muda o binário fora da lista (ex.: uma dep nova
  no `mix.exs` de outra app que o runner herde) deixaria um runner antigo conectar.
  Mitigação: lista conservadora, inclui `mix.lock`, `mix.exs` e `config/`; teste que
  falha se a lista divergir das apps do release `pipe_maestro_runner` em `mix.exs`.
- **Mudança de comportamento só no control plane** que um runner antigo interpreta
  diferente (campo novo de job montado fora do `protocol`): o `Job` mora no
  `protocol`, então mudanças de payload tendem a cair nos caminhos; o que for
  quebra de contrato continua subindo `protocol_version`.
- **Histórico com merges**: `git log -1 -- <caminhos>` é determinístico para um dado
  `HEAD`; CP e runner saem do mesmo checkout, então concordam. Clone raso no
  servidor quebraria o cálculo — o deploy usa clone completo (`git fetch --all`).
- **Docker sem `.git`**: precisa de `RUNNER_VERSION` como build arg, senão
  `dev+unknown` e todo runner recusado; `make image` passa os dois.
- **Recompilação**: `__mix_recompile__?/0` roda um `git log` a mais por compilação;
  custo pequeno.
- **Dialyzer/cobertura**: funções novas com `@spec`; `Version.Git` testado com repo
  temporário para não depender do checkout. Sem migração nem dados existentes
  afetados (o `runner_version` gravado dos runners continua igual).
