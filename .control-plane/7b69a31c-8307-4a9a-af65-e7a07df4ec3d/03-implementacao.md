# Implementação: diretor e2e e landing com as telas reais

Os testes da etapa 2 passam sem terem sido enfraquecidos. `make ci.quick` sai 0,
`make e2e` passa inteiro (22 testes) e `make e2e.typecheck` sai 0.

## Commits

| Commit | O quê |
|---|---|
| `2464055` | Runner: o relatório de mudanças agora funciona quando um caminho copiado já está no `.gitignore` (defeito encontrado pelo diretor) |
| `ac86747` | Diretor e2e (`make landing.shots`) e as 12 imagens |
| `becc877` | Landing: `LandingShots`, `landing_shot/1`, hero, tour `#produto`, menu "Produto" |
| `91cac8a` | Documentação: README do e2e, guia de UI, ADR 0030 |
| (este) | Fluxo D do `public-pages.spec.ts` marcado como `[done]` e este artefato |

## O que mudou, por app

### `pipe_maestro` (domínio) e `pipe_maestro_protocol`
Nada mudou. Não há migração nem mudança de mensagem, e runners antigos não são afetados.

### `pipe_maestro_runner`: correção fora do plano
- **Defeito:** se o diretório copiado para o worktree (por exemplo `deps`) estava no
  `.gitignore`, o `git add --all -- . ':(exclude)deps'` de `Changes.snapshot/2` falhava
  ("paths are ignored", código 1). O `snapshot` voltava `{:error, _}` e o job ia sem
  `changes`, então "arquivos alterados" sumiam da etapa e da tarefa. Qualquer projeto
  real cai nisso, porque `deps` costuma estar no `.gitignore`. O diretor mostrou o
  problema; o `createCodeRoot` das specs não tem `.gitignore` e por isso nunca o pegou.
- **Correção:** `changes.ex` deixa fora do pathspec os caminhos que o `git check-ignore`
  já ignora, porque o git já os exclui por conta própria.
- **Teste:** `changes_test.exs`, caso "a copied path that git already ignores does not
  break the snapshot". Ele falhou antes da correção com o mesmo erro.
- O runner continua sem Phoenix e sem Ecto, e o protocolo não mudou.

### `pipe_maestro_web`
- `controllers/landing_shots.ex` (novo): `PipeMaestroWeb.LandingShots.all/0` traz as
  seis telas (`board task decision audit usage runners`), cada uma com título, texto,
  `alt` e 2880×1800. `path/2` dá `<nome>.png` ou `<nome>-dark.png`.
- `PageController.home/2` passa `shots: LandingShots.all()`.
- `PageHTML.landing_shot/1`: uma janela de navegador (três pontos e o endereço
  `app.pipemaestro.dev/w/nimbus`, em markup e não em imagem) com duas `<img>`, uma
  `dark:hidden` e outra `hidden dark:block`, cada uma com `alt`, `width`, `height`,
  `loading` e `decoding="async"`.
- `home.html.heex`:
  - O hero ganhou `hero-screenshot`: o board com brilho em gradiente atrás, inclinação
    em perspectiva só a partir de `lg:` (nenhuma em `motion-reduce`) e a entrada
    `landing-rise` (só `motion-safe`, com keyframes em `app.css`).
  - O tour `#produto` (`product-tour`, `scroll-mt-16`) tem um bloco `tour-<nome>` por
    tela, com texto e imagem alternando de lado e badge numerado (Petal). No celular vira
    uma coluna.
  - "Recursos" perdeu os cards que o tour já mostra (runners, decisões, uso e auditoria).
  - `diagram-pipeline`, `diagram-architecture`, `diagram-stage` e `#como-funciona`
    continuam.
- `components/layouts.ex`: o link "Produto" (`nav-product`, `#produto`) vem antes de
  "Como funciona".
- `priv/static/images/landing/`: as 12 imagens têm de 224 KB a 408 KB, todas abaixo de
  600 KB.

#### Ajuste de implementação exigido por um teste (sem mudar o teste)
O teste "only the hero loads eagerly" trata como `eager` toda `<img>` cujo `src` aparece
no hero. O bloco `tour-board` usa o mesmo arquivo do hero, então essas duas imagens
também são `eager`. O navegador já baixou o arquivo para o hero, então não há custo
extra. Todas as outras são `lazy`.

### `e2e/` e `Makefile`
- `playwright.config.ts`: `chromium` e `mobile-chrome` declaram `testDir: "./tests"`. O
  projeto `director` (1440×900, escala 2, timeout de 10 min) só existe com
  `E2E_DIRECTOR=1`.
- `Makefile`: o alvo `landing.shots` (no `.PHONY` e no `make help`) depende de
  `e2e.db.reset` e `e2e.assets`.
- `helpers/runnerProcess.ts`: novas opções `claudeBin`, `env` e `configPrefix`. Os
  valores padrão não mudaram.
- `director/landing.spec.ts`: o roteiro. O operador cria o Nimbus e a Marina Costa. O
  runner `macbook-marina` (capacidade 4) sobe sobre `loja-api`, com o projeto
  "Loja API" (`make deps` e `make test`). São cinco tarefas de "Correção de bug": duas
  concluem, uma para com perguntas e duas ficam presas em `reproducao` e em
  `implementacao`. Depois das seis fotos, o diretor libera as tarefas presas e espera
  que terminem.
- `director/scenario.ts`: nomes, tarefas, mapa de cenas e o repositório `loja-api`
  (módulos, testes, `Makefile` e `bin/test`, que falha enquanto o bug existe).
- `director/capture.ts`:
  - grava o viewport em claro e em escuro;
  - `top` rola uma área até logo abaixo do cabeçalho;
  - esconde os toasts e o caminho absoluto do worktree;
  - falha se uma imagem passar de 600 KB;
  - `retext` troca o hostname da máquina e o endereço local por valores do cenário.
- `director/support/showcase_claude`: o CLI de vitrine, separado do `fake_claude`.
  - Imprime `stream-json` e roda ferramentas que mexem de verdade no worktree.
  - Os tempos das ferramentas batem com o tempo de relógio.
  - Exporta OTLP parcial antes de segurar uma etapa, para o "até agora" ter valor, e o
    restante no fim.
  - `LC_NUMERIC=C`: com locale pt-BR, o `sleep` recusava "0,30".

## Fora do plano ou diferente dele
- **Correção no runner**, descrita acima. O plano dizia que o runner não mudaria; a
  mudança é uma correção de defeito, não uma funcionalidade.
- **Enquadramento:** a foto é o viewport inteiro (1440×900 a 2×) em vez de um `clip`;
  `top` escolhe a área.
- **A foto `task`** começa na etapa "Reprodução com teste": artefato, passo a passo
  aberto e a saída do `make test`. Ela não mostra `task-files`, porque essa lista mostra
  os caminhos `.control-plane/<uuid da tarefa>/…`, e o critério de aceite proíbe UUID
  visível.
- **`retext` na foto `runners`:** sem ele, o hostname real do desenvolvedor e
  `localhost:<porta>` aparecem na imagem.

## Como verificar
```bash
mix test apps/pipe_maestro_web/test/pipe_maestro_web/controllers/   # LandingShots + landing
cd apps/pipe_maestro_runner && mix test test/pipe_maestro_runner/changes_test.exs
make ci.quick > /tmp/ciq.log 2>&1; echo $?                         # 0
make e2e                                                            # 22 passed
make e2e.shots FILE=tests/public-pages.spec.ts                      # hero e tour, claro/escuro, 1440 e 390 px
make landing.shots && git status                                    # regrava as mesmas 12 imagens (apaga o banco e2e)
make help | grep landing.shots
```

A auditoria visual foi feita sobre as imagens geradas e sobre as evidências do
`e2e.shots`, em claro e escuro, no desktop e no celular. Não há "e2e", "fake", UUID nem
hostname real nas imagens, e não há rolagem horizontal em 390 px. Nas capturas de página
inteira, as imagens `lazy` ainda não carregadas aparecem em branco; isso vem da captura,
e o spec confere que cada imagem carrega (`naturalWidth > 0`).

## Pendências
- `make ci` completo (com Dialyzer) não rodou nesta etapa; só `make ci.quick`. Fica para
  a etapa de verificação.
- Os bytes das imagens podem variar entre execuções do diretor (horários relativos, o
  fragmento do id no nome do branch). Os nomes e as dimensões não variam.
