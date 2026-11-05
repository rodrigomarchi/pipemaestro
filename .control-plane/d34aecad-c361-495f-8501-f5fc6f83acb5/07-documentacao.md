# Etapa 7 — Documentação e resumo

## Documentação

- **ADR:** nenhuma nova. A ADR 0019 (nome e marca próprias, sem fornecedor) continua valendo; o novo estilo é regra de UI e mora no guia. `docs/README.md` não muda.
- **Atualizados (nas etapas anteriores):** `docs/guias/ui-petal.md` §Marca (conceito visual, regras, `make favicon`) e `e2e/README.md` (`make favicon`, pasta `scripts/`).
- **Sem mudança:** `docs/specs/protocolo-runner.md`, `docs/guias/phoenix.md`, roadmap em `docs/plano/`.

## Resumo para quem vai revisar

### O que mudou e por quê
O símbolo do PipeMaestro ganhou estética cyberpunk: fundo escuro, trilhas de circuito a 45°, pads nos agentes e brilho neon violeta/ciano. O significado é o mesmo (agentes → pipeline → etapa → PR).

- **`apps/pipe_maestro_web`:** novo SVG em `brand_components.ex` (`logo_mark/1`, mesma API); `logo-mark.svg`, `logo-mark-mono.svg`, `favicon.svg` e `favicon.ico` redesenhados em `priv/static`. Testes novos em `test/pipe_maestro_web/components/` (`brand_components_test.exs`, `static_brand_test.exs`).
- **`e2e/` e `Makefile`:** `make favicon` e `e2e/scripts/favicon.mts` (rasteriza o SVG no Chromium do Playwright e monta o ICO); `e2e/tsconfig.json` cobre o script.
- **`apps/pipe_maestro`, `apps/pipe_maestro_protocol`, `apps/pipe_maestro_runner`:** sem mudança.

### Protocolo
Não mudou; nenhuma versão subiu. Runners antigos não são afetados.

### Riscos e pontos de atenção
- O quadrado escuro na sidebar escura depende do `ring` e da sombra colorida; olhe os shots escuros.
- Legibilidade em 16–28 px (favicon e sidebar recolhida).
- As classes Tailwind dos filhos do SVG estão literais no `.ex` para o scanner do Tailwind v4.
- **Pendência:** `make landing.shots` não rodou (exige o diretor com runner real). Os PNGs em `priv/static/images/landing/` ainda mostram o símbolo antigo na sidebar; regerar onde o runner real estiver disponível.

### Como verificar
- `make ci > /tmp/ci.log 2>&1; echo $?` (verde na etapa 5).
- `make e2e` (22 passaram) e `make e2e.shots FILE=tests/public-pages.spec.ts`.
- Para regerar o ícone: `make favicon`.
- Na tela: abra a landing, o login e o app nos temas claro e escuro, e confira o símbolo no cabeçalho, no rodapé e na sidebar (normal e recolhida), além do ícone da aba.
