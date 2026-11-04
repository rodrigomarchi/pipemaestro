# 03 — Implementação: versão do runner no formato AAAA-MM-DD.NN

Os testes da etapa 02 passam sem terem sido alterados. `make ci.quick` está verde, o Dialyzer
roda sem erros e `make e2e.shots` passa a suíte inteira, com capturas claras e escuras
conferidas.

## O que mudou, por arquivo

### Protocolo (`apps/claude_control_plane_protocol`)

- `lib/claude_control_plane_protocol/version.ex` (novo): o esquema, só com funções puras.
  `format/2`, `parse_tag/1` (só `runner-AAAA-MM-DD.NN`, com data válida, NN com 2 ou mais dígitos
  e ≥ 01), `parse/1` (`{:release, d, n}`, `{:dev, {d, n} | nil, sha}` ou `:unknown`), `next/2`,
  `describe/3`, `compare/2` e `outdated?/2`. Fica no protocolo porque é o contrato que o runner e
  o control plane compartilham.
- `lib/claude_control_plane_protocol/version/git.ex` (novo): a leitura do git com
  `git -C <dir>`. `current/1` usa `CP_VERSION` se não estiver vazia. Sem isso, usa
  `tag --points-at HEAD`, `tag --merged HEAD` e `rev-parse --short HEAD`, e cai em
  `dev+unknown` quando falta git ou repositório. Também tem `next/2` (todas as tags `runner-*`)
  e `local_today/0`.

### Runner (`apps/claude_control_plane_runner`)

- `lib/claude_control_plane_runner/version.ex` (novo): `@version Git.current(__DIR__)`, calculado
  na compilação. `__mix_recompile__?/0` recompila o módulo quando a versão mudaria (novo commit,
  nova tag, outro `CP_VERSION`).
- `host.ex`: `runner_version/0` delega para `Version.version/0`, e o Hello leva o valor novo.
- `main.ex`: os comandos `version` e `--version` existem, e o uso lista `cp-runner --version`.
- `commands/version.ex` (novo): imprime só a versão. Com `--next`, imprime a próxima release a
  partir do diretório atual e da data local.
- `lib/mix/tasks/runner.version.ex` (novo): `mix runner.version [--next]`.
- `commands/start.ex`: a primeira linha é `cp-runner <versão>`, antes de validar `--root`.
- `commands/status.ex`: imprime a linha `Versão: <versão>` antes do resumo das credenciais.
- `doctor.ex`: o primeiro item é `versão` (`:ok`, com a versão como detalhe), e o
  `cp-runner doctor` imprime `✓ versão: …`.

### Domínio (`apps/claude_control_plane`)

- `lib/claude_control_plane/version.ex` (novo): `build_version/0` vem embutida pela mesma
  mecânica do runner. `version/0` devolve a versão configurada
  (`config :claude_control_plane, ClaudeControlPlane.Version, version: …`, que os testes usam)
  ou, sem configuração, a do build. Também tem `__mix_recompile__?/0`.
- `runners.ex`: `outdated?(runner, reference \\ Version.version())` delega para
  `ClaudeControlPlaneProtocol.Version.outdated?/2`.

### Web (`apps/claude_control_plane_web`)

- `components/layouts.ex`: novo componente `app_version` (`data-testid="app-version"`, mono e
  discreto). Aparece no `<:footer>` da sidebar dos layouts `app` e `backoffice` e no rodapé do
  `public`. Nas páginas públicas sem navegação (login, ativação, seletor de workspace) aparece
  sobreposto ao pé da tela (`absolute bottom-4`), porque essas páginas já ocupam a tela inteira.
  Um rodapé no fluxo da página criava uma faixa abaixo da dobra.
- `components/runner_components.ex`: novo componente `runner_version` que mostra a versão
  (sem quebra de linha) e o badge Petal `warning`/`soft` "desatualizado" quando
  `Runners.outdated?/1` é verdadeiro. Os test ids são passados pelo chamador.
- `live/runners_live.ex`: a versão ganhou linha própria abaixo de host/OS
  (`runner-version-<nome>`, `runner-outdated-<nome>`). Na mesma linha do host, a coluna estreita
  quebrava a versão caractere a caractere, como se viu na primeira captura.
- `live/runner_live.ex`: o cabeçalho do card usa o componente (`runner-detail-version`,
  `runner-detail-outdated`).

### Build e operação

- `Makefile`:
  - o antigo `runner.release` passou a se chamar `runner.rel`, e `runner.install` depende dele;
  - novo `runner.version`;
  - novo `runner.release`. Ele recusa a execução se a árvore tiver mudanças ou se o HEAD já tiver
    uma tag `runner-*`. Depois calcula a próxima versão com `mix runner.version --next | tail -n 1`,
    confere o formato, cria a tag anotada e roda `make runner.binary`. Se o build falhar, explica
    como apagar a tag. No fim imprime o `git push origin runner-<versão>`, sem fazer o push;
  - `image` passa `--build-arg CP_VERSION=…`;
  - a lista `.PHONY` foi atualizada.
- `Dockerfile`: `ARG CP_VERSION` / `ENV CP_VERSION` antes da compilação, porque a imagem não
  tem `.git`.
- `mix.exs` (raiz): `binary_version/0` agora é `0.1.0+<release no HEAD ou sha>.<timestamp UTC>`.
  Cada build do Burrito sai com uma versão diferente.

### e2e

- `helpers/env.ts`: `versions` (`controlPlane: 2026-11-04.02`, `outdatedRunner: 2026-11-04.01`).
- `playwright.config.ts`: o servidor sobe com `CP_VERSION=versions.controlPlane`.
- `helpers/runnerProcess.ts`: aceita `{ version }` e passa `CP_VERSION` ao `mix runner.*`. Sem
  `version`, passa uma string vazia, para o runner nunca herdar a versão do servidor.
- `pages/RunnersPage.ts`: `version()`, `outdated()`, `detailVersion` e `detailOutdated`.
- `tests/runner-connection.spec.ts` (Flow B): o runner é a release antiga. A spec confere a saída
  `cp-runner 2026-11-04.01`, a versão e o selo na lista e na página do runner, e
  `app-version = 2026-11-04.02`.

## Saída

Testes direcionados, na raiz:

```
protocolo (version_test, version/git_test, protocol_test): Result: 70 passed
runner (mix test no app):                                   Result: 114 passed
domínio (version_test, runners_test):                       Result: 17 passed
web (app_version, runners_live, runner_live):               Result: 20 passed
```

`make ci.quick`:

```
MIX_ENV=test mix compile --warnings-as-errors --force
1865 mods/funs, found no issues.          (credo --strict)
Result: 70 passed
Result: 153 passed (1 doctest, 152 tests)
Result: 186 passed
Result: 114 passed
```

`mix dialyzer`: `Total errors: 0 … done (passed successfully)`.

`make e2e.shots`: `14 passed (1.4m)`. Capturas conferidas:
- `runner-online` (claro e escuro): versão e selo em linha própria;
- `runner-detail-no-recent-jobs-dark`: `runner 2026-11-04.01 [desatualizado]`;
- rodapé da sidebar com `2026-11-04.02`;
- login do backoffice (claro e escuro): versão no pé da tela.

`make runner.version` imprime `dev+e503fe3`, porque este repositório ainda não tem tag `runner-*`.

## O que fica para a etapa de documentação

O plano (§4) prevê:
- o ADR `0016-esquema-de-versao.md`;
- a seção de versões e releases em `docs/guias/instalacao.md`, que também deve explicar
  `runner.rel` e `CP_VERSION`;
- o exemplo do Hello em `docs/specs/protocolo-runner.md`, que ainda mostra `"0.1.0"`;
- o Marco 5 no roadmap.

`make runner.release` não foi executado de verdade: ele cria uma tag neste repositório e
compila o binário do Burrito. A lógica que ele usa (`next`) está coberta pelos testes.
