# Etapa 1 — Entendimento e plano

Tarefa: validar as versões no `make image` e exigir `CP_VERSION`/`RUNNER_VERSION` no
`Dockerfile`. Fecha as duas pendências das Consequências da
[ADR 0016](../../docs/adr/0016-esquema-de-versao.md).

Branch partindo de `origin/main` (`225fdfd`), já em dia: `git merge --ff-only origin/main`
respondeu "Already up to date" e não há commits alheios em `origin/main..HEAD`.

## Entendimento

Hoje (`Makefile`, alvo `image`):

```make
docker build --build-arg CP_VERSION=$$($(MAKE) -s cp.version) \
    --build-arg RUNNER_VERSION=$$($(MAKE) -s runner.version) \
    -t pipemaestro .
```

- `cp.version` e `runner.version` terminam em `| tail -n 1`: o status do `mix` se perde
  dentro do próprio alvo, e o da substituição `$(...)` se perde de novo no `docker build`.
  Com a compilação quebrada, a imagem sai com uma linha de erro (ou vazia) como versão.
- No `Dockerfile`, `ARG CP_VERSION=""` / `ARG RUNNER_VERSION=""`: vazias,
  `PipeMaestroProtocol.Version.Git.current/1` e `runner/1`
  (`apps/pipe_maestro_protocol/lib/pipe_maestro_protocol/version/git.ex`) não acham
  `.git` (o `.dockerignore` o exclui) e devolvem `dev+unknown`, sem aviso.

O que muda para quem usa:

- `make image` imprime as duas versões e só chama o `docker build` se ambas foram
  calculadas com sucesso e estão no esquema. Senão, para com mensagem em português
  dizendo qual versão falhou e o que veio.
- `docker build .` à mão, sem as versões, falha cedo apontando `make image` ou os
  `--build-arg`. Quem quer mesmo uma imagem sem versão passa
  `--build-arg ALLOW_UNVERSIONED=1` e tem o comportamento atual (`dev+unknown`).
- O deploy (Forgejo Actions → `scripts/deploy_sun.sh` → `scripts/deploy.sh`) não muda.

### Critérios de aceite (verificados rodando os comandos)

1. Compilação quebrada no `pipe_maestro_protocol` → `make image` sai ≠ 0 com
   `Não consegui calcular a versão do control plane: …` (ou do runner); nenhum passo do
   `docker build` aparece e `docker images pipemaestro` não ganha imagem nova.
2. Commit sem tag → aceita `AAAA-MM-DD.NN+dev.<sha>` ou `dev+<sha>` e constrói.
3. Versão `dev+unknown` ou vazia (simulada) → recusa.
4. `docker build -t x .` sem `--build-arg` → falha cedo com a mensagem que aponta
   `make image`.
5. `docker build --build-arg ALLOW_UNVERSIONED=1 -t x .` → constrói; a versão do control
   plane fica `dev+unknown`.
6. `make runner.release` continua exigindo a release pura, com a mesma expressão do
   Makefile (conferir pelo caminho de recusa, sem criar tag: árvore suja ou versão
   forjada).
7. Deploy sem mudança de comportamento, conferência registrada no PR.
8. ADR 0016 sem as duas pendências; `docs/guias/instalacao.md` com o comportamento novo.
9. `make ci` verde.

## Mudanças por app

- **`pipe_maestro`**: não muda.
- **`pipe_maestro_web`**: não muda.
- **`pipe_maestro_protocol`**: não muda. `PipeMaestroProtocol.Version` (`@release`,
  `@dev_on_release`, `@dev`) é a referência das expressões, mas a validação fica no
  Makefile (ver "Decisão de implementação").
- **`pipe_maestro_runner`**: não muda (`mix runner.version` segue igual).

O que muda é só de build e documentação: `Makefile`, `Dockerfile`,
`docs/adr/0016-esquema-de-versao.md`, `docs/guias/instalacao.md`.

### Decisão de implementação: validação no Makefile, não em Elixir

A tarefa permite as duas. Fica no Makefile porque:
- o `runner.release` já valida assim e a tarefa pede reaproveitar esse padrão;
- uma Mix task de validação teria de compilar o projeto, justamente o que pode falhar;
- não há regra de negócio nova, só a forma da string.

### `Makefile`

1. **Expressões definidas uma vez**, logo acima de `runner.version`, espelhando
   `PipeMaestroProtocol.Version` (com comentário apontando o módulo):
   ```make
   VERSION_RELEASE_RE = [0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{2,}
   VERSION_RELEASE    = ^$(VERSION_RELEASE_RE)$$
   VERSION_BUILD      = ^($(VERSION_RELEASE_RE)(\+dev\.[0-9a-z]+)?|dev\+[0-9a-z]+)$$
   ```
   (os nomes finais podem variar; `$$` porque são expandidas dentro de receitas.)
2. **`dev+unknown` e `X+dev.unknown`**: `unknown` casa com `[0-9a-z]+`, então a regex do
   protocolo sozinha aceitaria `dev+unknown`. O `image` recusa explicitamente o sha
   `unknown` (um segundo `grep -Eq '(^dev\+|\+dev\.)unknown$$'` que reprova). Um sha
   curto real é hexadecimal e nunca é `unknown`. Mantém-se `[0-9a-z]+` como pede a
   tarefa, em vez de restringir a `[0-9a-f]+`.
3. **`runner.release`** passa a usar `$(VERSION_RELEASE)` no `grep -Eq` existente, sem
   mudar comportamento nem mensagem.
4. **`cp.version` e `runner.version` propagam o status** do `mix`: capturam a saída
   numa variável, e se o `mix` falhar repassam a saída (stderr) e saem ≠ 0; senão
   imprimem a última linha. Sem `pipefail`: o Makefile não define `SHELL`, então roda
   `/bin/sh` (dash no Linux), e o padrão `out=$$(…) || { …; exit 1; }` é POSIX.
   Isso melhora os dois alvos para qualquer chamador; ninguém no deploy os chama
   (ver "Deploy").
5. **`image`** vira uma única receita de shell:
   ```sh
   cp=$$($(MAKE) -s cp.version) || { echo "Não consegui calcular a versão do control plane: $$cp"; exit 1; }
   echo "$$cp" | grep -Eq '$(VERSION_BUILD)' && ! echo "$$cp" | grep -Eq '<unknown>' || \
     { echo "Versão do control plane fora do esquema: '$$cp'"; exit 1; }
   (idem para o runner, "versão do runner")
   echo "Control plane $$cp, runner $$rv"
   docker build --build-arg CP_VERSION="$$cp" --build-arg RUNNER_VERSION="$$rv" -t pipemaestro .
   ```
   A mensagem de falha do cálculo inclui a saída capturada (a do `mix`, que sobe por
   stderr quando o alvo de versão falha, também fica visível). Provavelmente um pequeno
   `define` com a checagem, chamado duas vezes com `$(call …)`, para não duplicar.

### `Dockerfile`

- Novo `ARG ALLOW_UNVERSIONED=""` junto dos `ARG CP_VERSION` / `ARG RUNNER_VERSION`
  (lugar atual, depois do `COPY apps`, para mudar a versão não invalidar o cache das
  dependências) e, logo depois, antes do `RUN mix compile`:
  ```dockerfile
  RUN if [ -z "$CP_VERSION" ] || [ -z "$RUNNER_VERSION" ]; then \
        [ "$ALLOW_UNVERSIONED" = "1" ] || { \
          echo "Faltam as versões: use make image, ou passe --build-arg CP_VERSION=... --build-arg RUNNER_VERSION=... (--build-arg ALLOW_UNVERSIONED=1 para um build local sem versão)." >&2; \
          exit 1; }; \
      fi
  ```
  "Cedo" aqui = antes do `mix compile`, como pede a tarefa. As dependências vêm antes
  e ficam no cache; pôr a checagem antes delas faria cada versão nova recompilar os
  deps, o que é pior no uso normal.
- Comentário de cabeçalho: `make image` calcula e valida as versões; um build à mão
  precisa dos dois `--build-arg` ou de `ALLOW_UNVERSIONED=1`.
- Comentário perto dos `ARG`: sem `.git` na imagem, as versões vêm de fora; sem elas o
  build para, salvo `ALLOW_UNVERSIONED=1`, que mantém o `dev+unknown`.

## Deploy (conferência, sem mudança)

- `.forgejo/workflows/deploy.yml` roda `scripts/deploy_sun.sh main`, que manda o SSH para
  `scripts/deploy.sh` no servidor.
- `scripts/deploy.sh` faz `mix release` direto: versão `MIX_VERSION-SHORT_SHA` carimbada
  no `mix.exs`, e `RUNNER_VERSION` via `mix runner.version | tail -n 1` (linha 130),
  sem passar pelo `make`. `scripts/build_runner_binaries.sh` também chama o `mix`
  direto.
- Nenhum deles usa `Dockerfile`, `make image`, `make cp.version` nem
  `make runner.version` (conferido com `grep` no repositório). Portanto ficam
  intocados; a conferência vai no resumo do PR.

## Fronteiras

Nenhum código de app muda; a regra de dependências (runner só depende de `protocol`;
domínio sem web) não é tocada.

## Protocolo

Não toca `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels.
`docs/specs/protocolo-runner.md` não muda, a versão do protocolo não sobe, e runners
antigos seguem como hoje (a ADR 0016, decisão 5, já os aceita).

## Telas

Nenhuma. Sem `data-testid`, sem specs Playwright, sem `make e2e`.

## Testes

Não há teste automatizado de Makefile/Dockerfile no repositório, e a validação não vai
para Elixir, então não há ExUnit novo. Cada critério é verificado rodando o comando e
registrando saída e status no artefato da etapa de implementação (logs em `tmp/`):

| Critério | Como |
|---|---|
| 1 | erro de sintaxe temporário num `.ex` do `pipe_maestro_protocol`; `make image > tmp/image-quebrada.log 2>&1; echo $?`; conferir que não há `docker build` no log e que `docker images pipemaestro` não mudou; desfazer o erro (edição reversa, não `git checkout`) |
| 2 | `make image` no commit da branch (sem tag) → versão `…+dev.<sha>`, build completo |
| 3 | `CP_VERSION=dev+unknown make image` (o `cp.version` devolve o `CP_VERSION` do ambiente, via `Version.Git.current/1`) → recusa antes do `docker build`; idem `RUNNER_VERSION=dev+unknown` e `CP_VERSION=2026-11-04.01+dev.unknown`. O vazio não sai de `cp.version` com sucesso (vazio cai no git), então é provado rodando o mesmo trecho de validação isolado com `''` e `lixo` |
| 4 | `docker build -t pm-sem-versao .` → falha na checagem, antes do `mix compile` |
| 5 | `docker build --build-arg ALLOW_UNVERSIONED=1 -t pm-local .`; `docker run --rm pm-local bin/pipe_maestro eval 'IO.puts(PipeMaestro.Version.current())'` (ou a função equivalente) → `dev+unknown` |
| 6 | `make runner.release` com a árvore limpa não pode ser rodado sem criar tag; conferir pela leitura do alvo (usa `$(VERSION_RELEASE)`) e por `make -n runner.release`, mais o trecho de `grep` com `2026-11-09.01` (aceita) e `2026-11-09.01+dev.abc` (recusa) |
| 7 | `grep` por `make image`, `cp.version`, `runner.version`, `Dockerfile` em `.forgejo/` e `scripts/` |
| 9 | `make ci > tmp/ci.log 2>&1; echo $?` no fim |

Builds Docker completos levam minutos; rodar os critérios 2 e 5 uma vez cada.

## Documentação

- **ADR 0016** (`docs/adr/0016-esquema-de-versao.md`):
  - decisão 3: o `make image` calcula, valida no esquema e passa as duas versões por
    `--build-arg`; o `Dockerfile` as exige, salvo `ALLOW_UNVERSIONED=1`;
  - Consequências: tirar "Imagem sem `CP_VERSION`" e "`make image` não valida a
    versão"; no lugar, um item com o comportamento novo (o `image` recusa falha de
    cálculo, formato fora do esquema e `dev+unknown`; o `Dockerfile` para sem as
    versões; a exceção explícita para builds locais gera `dev+unknown`).
  - Não é decisão nova de arquitetura: ajuste da própria 0016, sem ADR nova.
- **`docs/guias/instalacao.md`** (seção "Imagem"): trocar "Num `docker build` feito à mão
  sem elas, as duas ficam `dev+unknown`…" pelo comportamento novo e pelo
  `--build-arg ALLOW_UNVERSIONED=1`, mantendo a remissão à seção 4 (sem selo de
  desatualizado num control plane `dev+unknown`).
- ADR 0035 (linha 40–41) só diz que a imagem recebe as duas versões: continua certa.

## Riscos

- **Shell do make**: sem `SHELL` definido, receitas rodam em `/bin/sh` (dash no Linux).
  Nada de `pipefail`, `[[ ]]` ou `local`; só POSIX. `grep -E` com `{4}` e `{2,}` é
  POSIX ERE, já usado no `runner.release`.
- **Escapes de `$`**: as variáveis com `$$` só podem ser expandidas em receitas; não
  usá-las em contexto de make puro.
- **`$(MAKE) -s`** dentro da receita: a saída do sub-make não traz "Entering directory"
  por causa do `-s`/`--no-print-directory`; manter `-s` e acrescentar
  `--no-print-directory` por segurança.
- **Mudar `cp.version`/`runner.version`**: qualquer script que dependa do status 0
  mesmo com falha quebraria; não há nenhum (só o `image` os chama).
- **Cache do Docker**: a checagem e os `ARG` ficam depois das dependências, como hoje.
- Sem migrações, dados, concorrência, cobertura ou dialyzer afetados (nenhum `.ex`
  muda).

## Commits previstos (etapa de implementação)

1. `build: make image valida as versões no esquema antes do docker build` (Makefile).
2. `build: Dockerfile exige CP_VERSION e RUNNER_VERSION, salvo ALLOW_UNVERSIONED=1`.
3. `docs: ADR 0016 e guia de instalação com a validação das versões da imagem`.
