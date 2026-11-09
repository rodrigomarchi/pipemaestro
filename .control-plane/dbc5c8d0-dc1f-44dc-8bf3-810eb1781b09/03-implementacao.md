# Etapa 3 — Implementação

## O que mudou

Nenhuma app do umbrella mudou de código. O que mudou foram os arquivos de build e a
documentação. O único arquivo de app tocado é o teste da etapa 2, que ganhou um ajuste.

| Arquivo | Mudança |
|---|---|
| `Makefile` | `VERSION_RELEASE_DAY`, `VERSION_RELEASE`, `VERSION_BUILD` e `VERSION_UNKNOWN`: o esquema de `PipeMaestroProtocol.Version` em `grep -E`, definido uma vez. `cp.version` e `runner.version` capturam a saída do `mix`; se ele falha, imprimem tudo e saem ≠ 0, senão imprimem a última linha. O `runner.release` usa `$(VERSION_RELEASE)`. O `image` calcula as duas versões (cada passo falha com o `mix`), valida com `VERSION_BUILD` menos `VERSION_UNKNOWN`, imprime `Control plane <v>, runner <v>` e só então roda o `docker build`. Os `grep` rodam com `LC_ALL=C`, para `[0-9a-z]` não aceitar maiúsculas em nenhum locale. O shell é POSIX, sem `pipefail` |
| `Dockerfile` | `ARG ALLOW_UNVERSIONED`, e um `RUN` no estágio `build`, depois dos `ARG` de versão e antes do `mix compile`: sem `CP_VERSION` ou sem `RUNNER_VERSION`, sai com mensagem que aponta `make image` e os `--build-arg`; com `ALLOW_UNVERSIONED=1`, avisa e segue (`dev+unknown`). Comentários de cabeçalho e dos `ARG` atualizados |
| `docs/adr/0016-esquema-de-versao.md` | Decisão 3 descreve o `image` validando e o `Dockerfile` exigindo as versões. As duas pendências das Consequências deram lugar a "A imagem só sai com versão válida" |
| `docs/guias/instalacao.md` | Seção "Imagem": o comportamento novo e o `--build-arg ALLOW_UNVERSIONED=1` |

### Ajuste no teste da etapa 2

`the Dockerfile refuses to build without the versions before mix compile` procurava o
primeiro trecho entre `RUN`s que contivesse `ALLOW_UNVERSIONED`. O trecho do
`RUN mix deps.get` vai até o próximo `RUN` e inclui a linha `ARG ALLOW_UNVERSIONED`,
então o teste pegava esse trecho e não a checagem. Passou a procurar
`$ALLOW_UNVERSIONED`, a variável lida por um comando. As asserções sobre o guarda não
mudaram: `CP_VERSION`, `RUNNER_VERSION`, `make image` e `exit 1`.

## Verificação

- `mix test test/pipe_maestro_protocol/version/image_build_test.exs` (no `protocol`) →
  `28 passed`.
- `make ci.quick > tmp/ciq.log 2>&1; echo $?` → `0` (cobertura total 83,49%).

### Critérios de aceite, rodando os comandos

| # | Comando | Resultado |
|---|---|---|
| 1 | arquivo temporário `apps/pipe_maestro_protocol/lib/quebrado_temporario.ex` com erro de sintaxe; `make image` | status 2, `Não consegui calcular a versão do control plane: Compiling 1 file (.ex) … (TokenMissingError) …`. Nenhum passo de `docker build` e a imagem `pipemaestro` continuou a mesma (`b48c7f1ca6e2`). O arquivo foi apagado em seguida |
| 2 | `make image` no commit `abe6b6b` (sem tag) | `Control plane dev+abe6b6b, runner dev+f6dc343`, status 0, imagem nova `1df5c540eaa7`. Dentro dela, `PipeMaestro.Version.build_version/0` e `build_runner_version/0` → `dev+abe6b6b / dev+f6dc343` |
| 3 | `CP_VERSION=dev+unknown make image`, `RUNNER_VERSION=dev+unknown make image`, `CP_VERSION=2026-11-04.01+dev.unknown make image` | status 2: `A versão do control plane está fora do esquema: 'dev+unknown'` (idem runner e `+dev.unknown`). Vazio e linha de erro: cobertos pelo ExUnit com `mix` falso |
| 4 | `docker build -t pm-sem-versao .` | status 1 no passo `[build 15/16]`, antes do `mix compile`: `Faltam as versões da imagem: use make image, ou passe --build-arg CP_VERSION=<versão> --build-arg RUNNER_VERSION=<versão> (para um build local sem versão, --build-arg ALLOW_UNVERSIONED=1).` |
| 5 | `docker build --build-arg ALLOW_UNVERSIONED=1 -t pm-local .` | status 0, com `Build local sem versão (ALLOW_UNVERSIONED=1): as duas ficam dev+unknown.`. Na imagem: `dev+unknown / dev+unknown`. A imagem `pm-local` foi apagada depois |
| 6 | `$(VERSION_RELEASE)` num makefile auxiliar com o `Makefile` | `2026-11-09.01` aceita; `2026-11-09.01+dev.abc` e vazio recusados. O `runner.release` usa a mesma variável, e o ExUnit garante que a expressão da data aparece uma vez só. O alvo não foi rodado, porque criaria uma tag |
| 7 | `grep` por `make image`, `cp.version`, `runner.version`, `Dockerfile` e `docker build` em `.forgejo/workflows/` e `scripts/` | só `scripts/build_runner_binaries.sh` faz `docker build`, e de `docker/runner-binary`, outra imagem. `deploy.yml` → `deploy_sun.sh` → `deploy.sh` faz `mix release` direto e chama `mix runner.version` sem `make`. Nada nesse caminho depende dos alvos alterados: ficou intocado |
| 8 | — | ADR 0016 e guia atualizados (acima) |
| 9 | `make ci.quick` | 0. O `make ci` completo, com dialyzer, fica para o gate; nenhum `.ex` mudou |

Logs em `tmp/` (fora do git): `image-quebrada.log`, `image-unknown.log`,
`docker-sem-versao.log`, `docker-local.log`, `make-image.log` e `ciq.log`.

## Observação

O `runner.release` ainda faz `mix runner.version --next | tail -n 1` sem capturar o
status. Não é um problema: a expressão da release pura recusa qualquer linha de erro, e
esse alvo está fora do escopo da mudança.
