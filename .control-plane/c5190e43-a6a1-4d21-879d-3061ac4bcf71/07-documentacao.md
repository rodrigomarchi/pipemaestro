# 07 — Documentação e resumo: versão do runner no formato AAAA-MM-DD.NN

## Documentação atualizada nesta etapa

- `docs/adr/0016-esquema-de-versao.md` (novo): formato, tag como fonte de verdade, builds de
  dev, versão embutida na compilação com `CP_VERSION`, esquema no `protocol`, regra do selo,
  `make runner.release` e `runner.rel`, semver do Burrito. As consequências trazem os riscos
  abertos.
- `docs/README.md`: o ADR 0016 entrou no índice.
- `docs/specs/protocolo-runner.md`: o exemplo do `Hello` usa `"2026-11-04.01"`, e uma nota diz
  que o formato é informativo. O protocolo e o `protocol_version` não mudam.
- `docs/guias/instalacao.md`:
  - `make image` com `CP_VERSION`, e o que acontece sem ela;
  - `runner.install` gera a release com `runner.rel`;
  - nova seção 4, "Versões e releases": a regra, onde a versão aparece, como gerar uma release
    (`git fetch --tags`, `make runner.release`, push manual) e quando o selo aparece.
- `docs/adr/0013-distribuicao-e-entrega-no-git.md`: nota sobre `runner.rel`, que substitui o
  antigo `runner.release`.
- `docs/plano/03-roadmap-orquestrador.md`: item 4 do Marco 5 marcado como feito.
- `AGENTS.md`: sem mudança. O `protocol` já lista "versions" no seu papel, e nenhum contexto
  novo de domínio foi criado (`PipeMaestro.Version` é utilitário, não contexto).

## Resumo para quem revisa e faz o merge

### O que mudou

- **Esquema** (`PipeMaestroProtocol.Version`, com a leitura do git em `Version.Git`):
  - uma release é `AAAA-MM-DD.NN`, vinda da tag anotada `runner-AAAA-MM-DD.NN`;
  - fora de uma release, a versão é `<release>+dev.<commit>`, `dev+<commit>` ou `dev+unknown`.
- **Runner**:
  - a versão é embutida na compilação (`PipeMaestroRunner.Version`) e vai no `Hello`;
  - novos `pipemaestro --version`/`version` e `mix runner.version [--next]`;
  - a versão aparece no `start`, no `status` e no `doctor`.
- **Control plane**:
  - `PipeMaestro.Version` e `Runners.outdated?/1,2`;
  - a versão aparece no rodapé da sidebar e no pé das páginas públicas (`app-version`);
  - a versão do runner e o selo "desatualizado" aparecem na lista e na página do runner.
- **Build**:
  - novo `make runner.release`: cria a tag e gera o binário, sem push;
  - o antigo `runner.release` passou a se chamar `runner.rel`;
  - `make image` passa `CP_VERSION`, e o `Dockerfile` a recebe;
  - a versão do Burrito ganhou o instante do build.
- Não há migration nem mudança de protocolo.

### Por quê

O runner se anunciava sempre como `0.1.0`. Ninguém sabia que build cada máquina rodava, nem se
estava atrás do control plane.

### Como verificar

- `make ci` e `make e2e` estão verdes (etapa 06).
- `make runner.version`: neste repositório, sem tags `runner-*`, imprime `dev+<commit>`.
- Para um teste manual de release, use um clone descartável. O `make runner.release` cria uma
  tag de verdade e precisa de Zig, `xz` e do Erlang do Burrito. No clone:
  - rode `make runner.release TARGET=<plataforma>`;
  - confira `git tag --points-at HEAD` e `burrito_out/pipemaestro_* --version`;
  - rode de novo e veja a recusa ("Este commit já é a release …").
- Nas capturas de `make e2e.shots`, confira `runner-online` e `runner-detail-*` (claro e
  escuro): a versão `2026-11-04.01` com o selo e o rodapé `2026-11-04.02`.

### Riscos e pendências

- **`make image` não valida a versão** (revisão, item 2). O alvo pega a última linha de
  `mix runner.version` sem conferir o formato. Se a compilação falhar, o `docker build` segue
  com essa linha como versão. A correção é validar com o mesmo `grep -Eq` do `runner.release`,
  aceitando também `+dev.<commit>` e `dev+…`. Ela não foi feita nesta etapa: o Bash exigia
  aprovação, e não havia como rodar a mudança. Vale um follow-up curto.
- **`git fetch --tags` antes da release**. Sem ele, a próxima versão pode repetir uma tag já
  publicada. O push dela falha, mas a tag local e o binário ficam errados. O guia pede o fetch.
- **Mudança de nome de `runner.release`**. Quem usava o alvo antigo agora cria uma tag. As
  recusas (árvore suja, HEAD já com tag) e o guia atenuam o risco.
- **Docker sem `CP_VERSION`**. A imagem fica `dev+unknown` e nenhum runner é marcado.
- **Versão visível sem login**. As páginas públicas mostram a versão, com o commit em builds
  de dev.
- **Pontos menores da revisão**, em aberto e sem efeito em produção:
  - `mix.exs` compara as tags do HEAD como strings;
  - `Version.compare/2` levanta erro fora de releases;
  - `--next` existe no binário;
  - a spec e2e depende da linha seguinte ao `pipemaestro <versão>`.
