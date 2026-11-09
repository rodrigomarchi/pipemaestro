# Etapa 7 — Documentação e resumo

## Documentação

- **ADR nova: não.** A mudança ajusta a [ADR 0016](../../docs/adr/0016-esquema-de-versao.md)
  (já atualizada na etapa 3): a decisão 3 e as Consequências descrevem o `make image`
  que valida e o `Dockerfile` que exige as versões, com a exceção `ALLOW_UNVERSIONED=1`.
  O índice de `docs/README.md` não muda.
- **Guia**: [`docs/guias/instalacao.md`](../../docs/guias/instalacao.md), seção "Imagem".
- **Sem mudança**: specs (`protocolo-runner.md` incluso), `ui-petal.md`, `phoenix.md`,
  `e2e/README.md` e o roadmap.

## Resumo para quem revisa

### O que mudou e por quê

Hoje a imagem do control plane podia sair com versão errada sem aviso: o status do
`mix` se perdia no `| tail -n 1` e no `$(...)` do `make image`, e o `Dockerfile` aceitava
as versões vazias (`dev+unknown`). Fecha duas pendências da ADR 0016.

- **`Makefile`**: as expressões do esquema ficam definidas uma vez
  (`VERSION_RELEASE`, `VERSION_BUILD`, `VERSION_UNKNOWN`), espelhando
  `PipeMaestroProtocol.Version`, e servem ao `image` e ao `runner.release`.
  `cp.version` e `runner.version` falham quando o `mix` falha. O `image` calcula as duas
  versões, aceita as três formas válidas (release, `+dev.<sha>`, `dev+<sha>`), recusa o
  resto (vazio, erro, `dev+unknown`), imprime as duas e só então chama o `docker build`.
- **`Dockerfile`**: sem `CP_VERSION` ou `RUNNER_VERSION`, o build para antes do
  `mix compile` apontando `make image`. `--build-arg ALLOW_UNVERSIONED=1` mantém o
  comportamento antigo para builds locais.
- **Por app**: `pipe_maestro`, `pipe_maestro_web` e `pipe_maestro_runner` não mudam.
  `pipe_maestro_protocol` ganha só um teste
  (`test/pipe_maestro_protocol/version/image_build_test.exs`), que roda o `make` com
  `mix` e `docker` falsos e confere a estrutura do `Dockerfile`.

### Protocolo

Não mudou: nada em `apps/pipe_maestro_protocol/lib` nem nas mensagens dos Channels, e a
versão do protocolo não sobe. Runners antigos seguem como estão.

### Deploy

`.forgejo/workflows/deploy.yml` → `scripts/deploy_sun.sh` → `scripts/deploy.sh` faz
`mix release` direto, sem `Dockerfile`, `make image`, `make cp.version` nem
`make runner.version`. Conferido com `grep`; ficou intocado.

### Riscos e o que olhar

- Quem usa `make cp.version` / `make runner.version` agora recebe status ≠ 0 se o `mix`
  falhar. Só o `image` os chama no repositório.
- O shell das receitas é o `/bin/sh` do make; usei só construções POSIX e `LC_ALL=C` nos
  `grep`. Vale rodar o `make image` numa máquina Linux.
- `dev+unknown` passa na regex do protocolo (`unknown` casa com `[0-9a-z]+`), por isso o
  `image` o recusa à parte (`VERSION_UNKNOWN`).
- Na etapa de CI, `gates_test.exs:54` do runner falhou uma vez e passou ao repetir, sem
  relação com esta mudança (detalhes em `05-ci.md`).

### Como verificar

```bash
cd apps/pipe_maestro_protocol && mix test test/pipe_maestro_protocol/version/image_build_test.exs
make image                                    # commit sem tag: dev+<sha>, constrói
CP_VERSION=dev+unknown make image             # recusa antes do docker build
docker build -t x .                           # falha cedo, aponta make image
docker build --build-arg ALLOW_UNVERSIONED=1 -t x .   # constrói, versões dev+unknown
make ci
```

Já executados e registrados em `03-implementacao.md` (comandos e resultados) e
`05-ci.md` (`make ci` verde). Sem tela, sem e2e.

### Documentos atualizados

`docs/adr/0016-esquema-de-versao.md`, `docs/guias/instalacao.md`.
