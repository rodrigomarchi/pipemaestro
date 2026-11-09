# Etapa 8 — Entrega

## Branch

`cp/validar-as-versoes-no-make-image-e-exigi-dbc5c8d0`, em cima de `origin/main`
(`225fdfd`). Não está em `main`. Não houve push nem PR aberto por mim: a plataforma
faz o push e marca o PR como pronto.

## Atualização com `origin/main`

`git fetch origin` e `origin/main` já é ancestral de `HEAD`: não havia nada novo para
trazer, então não houve merge, conflito nem rebase.

## Verificação

Como o merge não trouxe nada, não houve nova suíte. A árvore de código (`apps`,
`config`, `mix.exs`, `mix.lock`, `Makefile`, `Dockerfile`, `e2e`) está idêntica à do
último `make ci` verde (etapa 5, sobre `98315a2`). Desde então só entraram artefatos de
`.control-plane/`, e a etapa 6 não mudou nenhuma tela.

Ao contrário da etapa 5, que falhou uma vez em `gates_test.exs:54` e passou na segunda
execução, a árvore ficou fixa depois disso. Esse teste intermitente do runner continua
registrado em `05-ci.md`.

## Commits (`origin/main..HEAD`, do mais antigo ao mais novo)

| Commit | Mensagem |
|---|---|
| `4998056` | docs: plano para validar as versões no make image e no Dockerfile |
| `38816c5` | test: make image valida as versões e o Dockerfile as exige |
| `fa88558` | build: make image valida as versões no esquema antes do docker build |
| `f6dc343` | build: Dockerfile exige CP_VERSION e RUNNER_VERSION, salvo ALLOW_UNVERSIONED=1 |
| `abe6b6b` | docs: ADR 0016 e guia de instalação com a validação das versões da imagem |
| `0b0bca9` | docs: artefato da implementação |
| `98315a2` | docs: ajusta o texto de ALLOW_UNVERSIONED e a frase truncada da ADR 0016 |
| `20759ba` | docs: artefato da etapa de CI |
| `30745bc` | docs: artefato da etapa de telas (nenhuma tela mudou) |
| `95e1770` | docs: resumo para revisão da validação das versões da imagem |

As mensagens estão em português. Os commits `fa88558` e `f6dc343` ficaram com uma
descrição de corpo, e o do teste também.

## Resumo para revisão

Hoje a imagem do control plane podia sair com versão errada sem aviso: o status do
`mix` se perdia no `| tail -n 1` e no `$(...)` do `make image`, e o `Dockerfile`
aceitava as versões vazias (`dev+unknown`). Esta mudança fecha as duas pendências da
ADR 0016.

- **`Makefile`**: o esquema de versão fica definido uma vez
  (`VERSION_RELEASE`, `VERSION_BUILD`, `VERSION_UNKNOWN`), espelhando
  `PipeMaestroProtocol.Version`, e serve ao `image` e ao `runner.release`.
  `cp.version` e `runner.version` falham quando o `mix` falha. O `image` calcula as
  duas versões, aceita só as três formas válidas, imprime as duas e só então chama o
  `docker build`.
- **`Dockerfile`**: sem `CP_VERSION` ou `RUNNER_VERSION`, o build para antes do
  `mix compile` e aponta `make image`. `--build-arg ALLOW_UNVERSIONED=1` mantém o
  comportamento antigo, só para builds locais.
- **Apps**: `pipe_maestro`, `pipe_maestro_web` e `pipe_maestro_runner` não mudam.
  `pipe_maestro_protocol` ganha só o teste
  `test/pipe_maestro_protocol/version/image_build_test.exs`.
- **Protocolo**: não mudou. Runners antigos seguem como estão.
- **Deploy**: `deploy.yml` → `deploy_sun.sh` → `deploy.sh` não passa pelos alvos
  alterados. Conferido e intocado.
- **Riscos**: `make cp.version` e `make runner.version` agora saem com erro quando o
  `mix` falha. O `image` é o único chamador no repositório. As receitas usam só
  construções POSIX; vale rodar `make image` numa máquina Linux.

## Documentos

`docs/adr/0016-esquema-de-versao.md` e `docs/guias/instalacao.md`. Nenhuma ADR nova.
