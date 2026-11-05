# Etapa 3 — Implementação: logo cyberpunk do PipeMaestro

Os 12 testes que falhavam na etapa 2 passam, sem mudar nenhum teste.

## O que mudou

### `apps/pipe_maestro_web`

- `lib/pipe_maestro_web/components/brand_components.ex` — novo desenho de `logo_mark/1`
  (mesma API, `@spec`, `viewBox`, `role` e `<title>`):
  - `<svg>` com `bg-gradient-to-br from-primary-950 to-secondary-950`,
    `ring-1 ring-primary-400/30` e `shadow-md shadow-primary-500/40` (destaca o quadrado
    escuro da sidebar escura);
  - trilhas `stroke-primary-400` com cantos a 45° (`M9 9H11L18 16`, `M9 16H19.6`,
    `M9 23H11L18 16`), três pads vazados `r=2` em `x=7`, anel `stroke-secondary-400`
    (`cx=21.5`, `r=1.9`) e ponto do PR `fill-secondary-400` (`cx=26.5`, `r=2.75`);
  - halo: cópias mais largas com `stroke-opacity="0.3"` por baixo de cada grupo; sem `id`,
    `<defs>`, `<filter>`, animação nem `currentColor`;
  - `@moduledoc`/`@doc` descrevem o novo desenho.
- `priv/static/images/logo-mark.svg` — mesmo desenho com cores literais (`#2e1065 →
  #082f49`, `#a78bfa`, `#38bdf8`), autocontido.
- `priv/static/images/logo-mark-mono.svg` — trilhas, pads, anel e ponto só em
  `currentColor`, sem fundo nem halo.
- `priv/static/images/favicon.svg` — simplificado: fundo escuro `rx=7`, dois agentes em
  trilhas de 45° largas (3) com halo de 5.5 translúcido, ponto ciano `r=4.5`.
- `priv/static/favicon.ico` — regerado (PNGs de 16/32/48 px) com `make favicon`.
- `layouts.ex` e `root.html.heex`: sem mudança (o nome da marca já lê bem nos dois temas).

### `e2e/` e raiz

- `e2e/scripts/favicon.mts` — rasteriza o `favicon.svg` no Chromium do Playwright e
  empacota os três PNGs num ICO (sem dependência nova). Extensão `.mts` para o Node 25
  rodar o TypeScript direto como ESM sem aviso de tipo de módulo e sem mudar o
  `package.json` (o que afetaria a configuração do Playwright).
- `e2e/tsconfig.json` — `include` passa a cobrir `scripts/*.mts`, então
  `make e2e.typecheck` verifica o script.
- `Makefile` — alvo `make favicon` (com `##` para o `make help`).

### `docs/` e READMEs

- `docs/guias/ui-petal.md` §Marca — novo estilo (fundo escuro, neon primary/secondary,
  trilhas a 45°, pads, halo por traço duplicado), regras (sem animação, sem `filter`,
  sem ids no inline) e `make favicon`.
- `e2e/README.md` — `make favicon` na lista de comandos e a pasta `scripts/`.

### `apps/pipe_maestro`, `apps/pipe_maestro_protocol`, `apps/pipe_maestro_runner`

Sem mudança. Protocolo intacto.

## Verificação

- `cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/components/` → 64 passed;
  suíte do web app → 315 passed.
- `make ci.quick` → saída 0.
- `make e2e.typecheck` → ok; `make e2e` → 22 passed.
- `make e2e.shots FILE="tests/public-pages.spec.ts tests/user-session.spec.ts"` → 8
  passed; auditados `01-brand`, `01-board-dark` (sidebar escura): símbolo legível em
  28–32 px, ring separa o quadrado do fundo escuro, halo sem borrão. Os PNGs do `.ico`
  (16 e 48 px) também conferidos: leitura mantida em 16 px.
- Para regerar o `.ico` depois de mexer no favicon: `make favicon`.

## Pendências

- `make landing.shots` não foi rodado: zera o banco e2e e precisa do diretor com runner
  real; os PNGs de `priv/static/images/landing/` ainda mostram o símbolo antigo na
  sidebar. Fica para a entrega/revisão rodar onde o runner real estiver disponível.
- `make ci` completo (com Dialyzer) fica para a etapa de verificação; nenhuma `@spec`
  mudou.
- Glitch cromático opcional do plano não entrou: o desenho já lê bem sem ele.
