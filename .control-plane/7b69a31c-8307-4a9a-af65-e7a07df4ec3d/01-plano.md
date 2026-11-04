# Plano: diretor e2e que fotografa a plataforma e landing com imagens reais

Base: branch atualizada por fast-forward até `origin/main` (`777844a`, PR #9 do logo).
Nenhum commit fora desta tarefa em `origin/main..HEAD`.

## Entendimento

Hoje a landing (`PageController.home/2` → `controllers/page_html/home.html.heex`, dentro de
`Layouts.public`) só tem ilustrações em Tailwind. Quem chega não vê o produto. A mudança:

1. um **diretor** Playwright (`e2e/director/`) monta, pela interface e com um runner real,
   um workspace realista e fotografa as telas que a landing mostra, em claro e escuro;
2. as fotos ficam versionadas em `apps/pipe_maestro_web/priv/static/images/landing/`;
3. a landing ganha um hero com o screenshot real num frame de navegador e um tour do produto
   (`#produto`), sem perder os diagramas de arquitetura e de etapa.

Critérios de aceite verificáveis (os da tarefa, com a prova de cada um em "Testes"):

- `make landing.shots` recria o banco e2e, compila os assets e gera
  `board`, `task`, `decision`, `audit`, `usage`, `runners` (`.png` e `-dark.png`); rodar de
  novo sobrescreve os mesmos nomes.
- Cada imagem < ~600 KB, sem sufixo aleatório, UUID, "e2e" ou "fake" visível.
- `make e2e` / `make e2e.shots` não executam o diretor nem tocam em `priv/static/images/landing/`.
- Landing com `hero-screenshot`, `product-tour` e um `tour-<nome>` por tela, tema certo em
  claro e escuro, sem rolagem horizontal em 390 px.
- `page_controller_test.exs` confere os testids e que cada imagem referenciada existe.
- `public-pages.spec.ts` confere hero e tour e faz `shot()` em desktop e 390 px; `make e2e` verde.
- `make ci` e `make e2e.typecheck` verdes; `e2e/README.md` documenta o diretor; `make help`
  lista `landing.shots`.

## Mudanças por app

### `pipe_maestro` (domínio) — **não muda**

Nenhum contexto, schema ou migração. O diretor usa só o que a interface já oferece.

### `pipe_maestro_protocol` — **não muda**

### `pipe_maestro_runner` — **não muda**

Nem o código nem `test/support/fake_claude`. O roteiro rico do diretor é um **CLI de
vitrine separado**, `e2e/director/support/showcase_claude` (shell, mesmo formato
`stream-json` do `fake_claude`), apontado por `CLAUDE_BIN` só no runner do diretor. Assim
as specs atuais, que dependem das saídas exatas do `fake_claude`, ficam intocadas por
construção. (Alternativa descartada: um gancho opt-in por variável de ambiente dentro do
`fake_claude`; funciona, mas mistura vitrine com fixture de teste e arrisca as specs.)

### `pipe_maestro_web`

1. **Imagens da landing como dado** — módulo novo `PipeMaestroWeb.LandingShots`
   (`lib/pipe_maestro_web/controllers/landing_shots.ex`, `@moduledoc`, `@spec`): a lista
   das telas, cada uma com `name`, título curto, frase, `alt` em português, `width`/`height`
   em pixels e a função `path(name, :light | :dark)`. O template e o teste leem dela; nada de
   nome de arquivo espalhado. `PageController.home/2` passa `shots: LandingShots.all()`.
2. **Componente** `landing_shot/1` (em `PageHTML` ou num `LandingComponents` pequeno):
   duas `<img>` — `class="dark:hidden"` e `class="hidden dark:block"` — com
   `src={~p"/images/landing/#{name}.png"}`, `alt`, `width`, `height`, `loading` (`eager`
   no hero, `lazy` no resto) e `decoding="async"`. O tema segue a classe `dark` do
   `<html>`, que é o que o `color_scheme_switch` alterna.
3. **Hero** (`home.html.heex`): título e CTAs como hoje; abaixo, `hero-screenshot`: o board
   num frame de janela de navegador (barra com três pontos e um "endereço" fictício
   `app.pipemaestro.dev/w/nimbus`, borda arredondada), com sombra e brilho em
   `primary`/`secondary` (gradiente borrado atrás), leve inclinação em perspectiva só a
   partir de `lg:` e entrada animada (`motion-safe:animate-[...]`; keyframes no
   `assets/css/app.css`). Em `motion-reduce` a imagem aparece parada e sem inclinação.
   O `hero-journey` continua como faixa de passos logo abaixo da imagem.
4. **Tour** `#produto` (`product-tour`): **blocos alternados texto/imagem**, sem JS (um
   bloco `tour-<nome>` por tela: `board` "Acompanhe ao vivo", `task` "Cada etapa à vista",
   `decision` "Decida quando o agente para", `audit` "Audite cada execução", `usage`
   "Controle o custo", `runners` "Roda na sua máquina"). Cada imagem no mesmo frame de
   navegador (versão plana), `loading="lazy"`. No celular vira uma coluna; a imagem ocupa
   `w-full` e o frame não usa transform, então não há rolagem horizontal. Petal: `.badge`
   para o rótulo de cada bloco, `.button` nos CTAs; o frame é markup próprio (não há
   componente Petal de "browser mockup").
5. **Seções existentes**: `#como-funciona` (criança) e `diagram-pipeline` continuam, mas o
   tour vem logo depois do hero; `diagram-architecture` e `diagram-stage` ficam (exigência).
   `#recursos` é enxugado: os cards que o tour já mostra (uso e auditoria, decisões) saem
   ou viram uma linha, para não repetir. `#seguranca` fica.
6. **Menu** do `Layouts.public` (`components/layouts.ex`, nav `hidden md:flex`): link
   "Produto" → `#produto` (testid `nav-product`) antes de "Como funciona".

## Fronteiras

- Domínio e runner não mudam; nada novo depende de web.
- O diretor é TypeScript em `e2e/`, fora do umbrella. O `showcase_claude` vive em
  `e2e/director/support/`, não no runner: o release do runner não o carrega.

## Protocolo

Não toca `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels. O
`showcase_claude` imprime o mesmo `stream-json` que o CLI real e o `fake_claude` já
imprimem, consumido pelo `JobRunner` sem mudança. Sem mudança em
`docs/specs/protocolo-runner.md`, sem subir versão; runners antigos não são afetados.

## O diretor (`e2e/`)

### Configuração e execução

- `e2e/playwright.config.ts`: projetos `chromium` e `mobile-chrome` ganham
  `testDir: "./tests"` explícito; o projeto `director` (`testDir: "./director"`, viewport
  1440×900, `deviceScaleFactor: 2`, `timeout` longo) **só existe na lista quando
  `E2E_DIRECTOR=1`**. Assim `make e2e`/`e2e.shots` (que não passam `--project`) nem
  enxergam o diretor.
- `Makefile`: alvo `landing.shots: e2e.db.reset e2e.assets ## ...` (no `.PHONY`), que mata o
  servidor da porta e roda
  `cd e2e && $(E2E_ENV) E2E_DIRECTOR=1 npx playwright test --project=director`. O
  `global-setup.ts` recria o operador no banco limpo (único dado fora do navegador).

### Arquivos

- `e2e/director/landing.spec.ts` — o roteiro, um teste serial, cabeçalho
  `@section`/`@flow` como as specs.
- `e2e/director/capture.ts` — `capture(target, name, { clip? })`: espera estado (testids),
  esconde toasts por `style` do screenshot (`[data-testid="toasts"]{visibility:hidden}`),
  `animations: "disabled"`, grava `<name>.png`, troca para escuro como o `shot()`
  (`emulateMedia` + classe `dark`), grava `<name>-dark.png`, volta ao claro. Escreve em
  `../apps/pipe_maestro_web/priv/static/images/landing/` e **falha** se um arquivo passar
  de 600 KB ou se as dimensões divergirem do esperado — o desenvolvedor ajusta o
  enquadramento ali, em vez de descobrir no PR.
- `e2e/director/scenario.ts` — dados realistas: workspace **Nimbus** (`nimbus`), membro
  **Marina Costa** (`marina@nimbus.dev`), runner **`macbook-marina`**, diretório
  **`loja-api`**, tarefas com títulos de engenharia (ex.: "Corrigir arredondamento do
  total com cupom", "Exportar pedidos em CSV", "Paginar a listagem de clientes").
- `e2e/director/support/showcase_claude` — o CLI de vitrine: modelo com nome plausível,
  várias ferramentas por etapa (Read, Grep, Edit, Bash `make test`), edições reais em
  arquivos do worktree (para "arquivos alterados"), artefato Markdown por etapa, custo e
  tokens plausíveis, export OTLP mais rico (para a auditoria: tempo por ferramenta,
  origem das chamadas), `session_id` legível (sem UUID). O comportamento de cada tarefa
  vem de um **mapa de cenas** que o diretor grava num arquivo (`SHOWCASE_SCENES`, linhas
  `frase|comportamento`), casado com uma frase da descrição da tarefa — sem marcadores
  como `[lento]` visíveis no prompt. Comportamentos: `ok`, `perguntas` (bloqueia com
  perguntas estruturadas e opção recomendada), `segura:<etapa>` (emite os primeiros steps
  e espera até existir o arquivo `$SHOWCASE_DIR/release`, com teto de segurança, para a
  tarefa ficar "rodando" na hora da foto). Responde também aos `pipemaestro-kind`
  necessários (`decision`/`analysis`) se a sugestão do agente for fotografada.
- `e2e/helpers/runnerProcess.ts` — extensão compatível: opções `claudeBin`, `env` extra
  e `codeRoot` customizável (ou um `createCodeRoot` do diretor que monta `loja-api`: um
  repo git com `lib/`, `test/`, `Makefile` cujo `test` imprime uma saída plausível, e
  `deps/`). Os padrões atuais não mudam. `configDir` com prefixo neutro para o diretor
  (o caminho do worktree aparece na tela da tarefa e não pode conter "e2e").
- Page Objects reaproveitados (`BackofficePage`, `AppPage`, `RunnersPage`,
  `PipelinesPage`, `ProjectsPage`, `TasksPage`, `JobsPage`); o que faltar (ex.: abrir o job
  de uma etapa a partir da tarefa) entra como método novo, sem mudar os existentes.

### Roteiro

1. Operador cria o workspace Nimbus e a Marina; Marina entra, cria os pipelines prontos
   (`PipelinesPage.createDefaults`) e o projeto `loja-api` (setup e `make test`).
2. Runner `macbook-marina` faz login (device flow pela tela) com `--capacity 4` e sobe com
   `--root` do código de exemplo e `CLAUDE_BIN=showcase_claude`.
3. Tarefas: duas que concluem (esperar `task-status` final), uma que para com perguntas
   (esperar o painel de decisão), uma segurada numa etapa do meio (esperar a etapa rodando e
   steps na linha do tempo).
4. Fotos (cada uma claro + escuro, viewport 1440, escala 2):
   - `board` — o board com as colunas, a tarefa rodando, a de decisão, as concluídas, e o
     runner online;
   - `task` — a tarefa segurada: etapas, steps abertos (`openSteps`) e `task-files`;
   - `decision` — a tarefa com perguntas: `decision-panel` e o questionário com a opção
     recomendada (a sugestão do agente);
   - `audit` — a página do job de uma etapa concluída, enquadrando `job-audit`
     (tempo, ferramentas, custo), sem a linha da sessão se ela destoar;
   - `usage` — custo por etapa e por origem;
   - `runners` — a lista com o runner online e a versão.
5. Cria `release`, espera a tarefa segurada terminar, para o runner e limpa.

Enquadramento: `clip` de tamanho fixo por tela (ex.: 1440×900 do conteúdo útil), para que
`width`/`height` sejam estáveis e o `LandingShots` declare os valores certos.

## Telas

- **Muda:** só a landing (`/`) e o menu do `Layouts.public`. Telas internas não mudam (se o
  diretor revelar defeito visual, corrige-se o defeito, sem redesenho).
- **Testids novos:** `hero-screenshot`, `product-tour`, `tour-board`, `tour-task`,
  `tour-decision`, `tour-audit`, `tour-usage`, `tour-runners`, `nav-product`.
- **Spec:** `e2e/tests/public-pages.spec.ts` — fluxo A passa a conferir `hero-screenshot`
  visível com a imagem carregada (`naturalWidth > 0`), `product-tour` e cada `tour-<nome>`,
  e que em escuro a `<img>` visível é a `-dark`; `shot()` da landing em desktop e em 390 px
  (já existe) mais `shot()` do hero e do tour; checagem de `scrollWidth <= clientWidth` em
  390 px.

## Testes

- **ExUnit** (`apps/pipe_maestro_web/test/pipe_maestro_web/controllers/page_controller_test.exs`):
  - a landing tem `hero-screenshot`, `product-tour`, `tour-<nome>` de cada tela e `nav-product`;
  - toda imagem que o HTML referencia (`src="/images/landing/..."`, extraídas da resposta)
    existe em `priv/static/images/landing/` (via `Application.app_dir/2`), claro e escuro;
  - cada `<img>` da landing tem `alt` não vazio, `width` e `height`; as fora do hero têm
    `loading="lazy"`;
  - teste do `LandingShots`: cada PNG tem largura/altura (cabeçalho IHDR) iguais às
    declaradas e tamanho < 600 KB — pega imagem regenerada com enquadramento diferente.
- **Playwright**: `public-pages.spec.ts` como acima; `make e2e` verde e sem tocar
  `priv/static/images/landing/` (o diretor não existe sem `E2E_DIRECTOR`).
- **Diretor**: `make landing.shots` duas vezes; `git status` só mostra os mesmos 12 arquivos.
- **Auditoria visual**: `make e2e.shots FILE=tests/public-pages.spec.ts`, claro/escuro,
  desktop e celular; e conferência visual de cada imagem gerada (sem "e2e", "fake", UUID).
- `make ci` e `make e2e.typecheck` (o `tsconfig` já inclui `**/*.ts`, então o diretor entra).

## Documentação

- `e2e/README.md`: seção **"Diretor da landing"** — exceção deliberada a "nunca escreva
  uma spec só para screenshot"; roda à parte (`make landing.shots`, `E2E_DIRECTOR`) e
  **apaga o banco e2e**; grava em `apps/pipe_maestro_web/priv/static/images/landing/`;
  rodar de novo quando uma tela mostrada na landing mudar; o `showcase_claude` e o mapa de
  cenas. Ajustar a frase da regra "Caixa-preta" (nomes únicos) para citar a exceção.
- `make help` lista `landing.shots` (pelo comentário `##`).
- `docs/guias/ui-petal.md`: nota curta sobre `landing_shot` (par claro/escuro por classe
  `dark`, `width`/`height`, `lazy`).
- **ADR `0030-screenshots-reais-da-landing.md`**: imagens geradas localmente por um diretor
  e2e e versionadas (não no CI/deploy), com runner real e CLI de vitrine separado do
  `fake_claude`; alternativas (gerar no CI, ilustrações, gancho no `fake_claude`).
  Entrada em `docs/README.md` se ele lista as ADRs.

## Riscos

- **Tamanho das imagens**: 1440×900 a 2× em PNG pode passar de 600 KB (telas com muito
  texto). Mitigação: `clip` menor por tela; o `capture` falha acima do limite. JPEG só se
  necessário, e então o `LandingShots` declara a extensão por tela (o teste do IHDR passa a
  valer só para PNG).
- **Determinismo**: a tarefa "rodando" depende do `release` e do teto do `showcase_claude`;
  relógios relativos ("há 3 s") e o fragmento do id no nome do branch (`cp/...-xxxxxxxx`)
  podem variar entre execuções — aceitável (não é UUID nem altera layout), mas se um
  relógio mudar a largura, esconder pelo `style` da captura. O nome dos arquivos é sempre
  o mesmo; o conteúdo dos bytes pode variar.
- **Caminhos na tela**: `task-worktree` mostra o caminho absoluto do worktree; o diretor usa
  um `configDir` com nome neutro e, se ainda destoar, o enquadramento o exclui.
- **Peso da página**: 12 imagens; só o hero é `eager`, o resto `lazy`; dimensões explícitas
  evitam CLS.
- **Cobertura/Dialyzer**: `LandingShots` e o componente ficam cobertos pelos testes do
  controller; `@spec` em tudo público.
- **`e2e.db.reset` apaga o banco e2e** do worktree; documentado.
- Sem migração, sem dado existente afetado, sem concorrência nova no servidor.
