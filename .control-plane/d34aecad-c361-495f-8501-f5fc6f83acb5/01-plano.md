# Etapa 1 — Entendimento e plano: logo do PipeMaestro com estética cyberpunk

Branch `cp/redesenhar-o-logo-do-pipemaestro-com-est-d34aecad`, em dia com `origin/main`
(`0cde6a9`, sem commits próprios antes deste plano).

## Entendimento

Hoje o símbolo (`PipeMaestroWeb.BrandComponents.logo_mark/1`) é um quadrado arredondado
com gradiente `primary-500 → secondary-500` e traços brancos em Bézier. A tarefa troca só
o desenho: **fundo escuro, trilhas de circuito com cantos a 45°, pads/vias nos agentes e
brilho neon violeta/ciano**. O significado não muda (ADR 0019, `docs/guias/ui-petal.md`
§Marca): três agentes → um pipeline → uma etapa (anel) → o pull request (ponto cheio).

Para quem usa, muda a aparência da marca em todas as telas que usam `Layouts.brand/1`
(header e rodapé da landing, sidebars do app e do backoffice, login, seleção de workspace,
ativação do runner) e o ícone da aba (favicon). Nenhum fluxo, rota, texto ou test id muda.

### Critérios de aceite verificáveis

1. `logo_mark/1` mantém a API (`class`, `rest`), `viewBox="0 0 32 32"`, `role="img"` e
   `<title>PipeMaestro</title>`; o `@moduledoc` descreve o novo desenho.
2. O `<svg>` inline não tem atributo `id` em nenhum elemento, nem `<text>`, `<image>`,
   `<defs>`/`<filter>`/`<linearGradient>`, nem nome de terceiros.
3. O `<svg>` inline tem as classes de fundo escuro (`from-primary-950`/`to-secondary-950`)
   e de contorno/brilho esperadas.
4. `logo-mark.svg` (cores literais, autocontido), `logo-mark-mono.svg` (só `currentColor`,
   sem fundo nem glow), `favicon.svg` (simplificado) e `favicon.ico` (16/32/48) atualizados
   e válidos.
5. Test ids `brand`, `brand-mark`, `footer-brand`, `footer-brand-mark` iguais;
   `e2e/tests/public-pages.spec.ts` e `e2e/tests/user-session.spec.ts` passam sem mudar
   seletor.
6. `make e2e.shots` auditado (shots `brand`, `login-brand` e a sidebar do app, claro e
   escuro); `make landing.shots` regerado; `make ci` e `make e2e` verdes.

## Desenho proposto (viewBox 32×32)

Coordenadas de partida; a etapa de implementação pode ajustar meio ponto após auditar os
shots, sem mudar a estrutura.

- **Fundo:** quadrado `rx` 8 (o `rounded-lg` atual), gradiente escuro
  `primary-950 → secondary-950` (literais `#2e1065 → #082f49` no estático).
- **Trilhas (violeta neon, `primary-400` `#a78bfa`, largura ~1.75, `stroke-linejoin`
  miter/round):** três agentes saem retos e dobram a 45° para o mesmo nó:
  - topo `M9 9 H11 L18 16`;
  - meio `M9 16 H18`;
  - baixo `M9 23 H11 L18 16`;
  - pipeline `M18 16 H19.5` até o anel.
- **Pads/vias dos agentes:** círculos `r≈2` com traço `primary-400` e miolo escuro (o
  fundo aparece pelo furo), em `x=7`, `y=9/16/23`.
- **Etapa (anel):** círculo vazado ciano (`secondary-400` `#38bdf8`) em `cx≈21.5`, `r≈1.9`.
- **Pull request:** ponto cheio ciano em `cx≈26.5`, `r≈2.75`.
- **Brilho:** cada grupo de traços tem uma cópia por baixo, mais larga (+2 a +2.5) e
  translúcida (`stroke-opacity`/`opacity` ~0.35), na mesma cor. Isso dá o halo neon
  **sem `filter` nem ids**, renderiza igual no navegador e no rasterizador e não vira
  borrão em 28 px. No inline, um brilho externo leve no próprio `<svg>`
  (`shadow-[0_0_10px] shadow-primary-500/40` ou `drop-shadow` equivalente) e um anel fino
  (`ring-1 ring-primary-400/30`) separam o quadrado escuro do fundo escuro da sidebar no
  tema escuro; no claro, o próprio quadrado escuro dá o contraste.
- **Glitch (opcional):** não entra por padrão. Se os shots mostrarem que cabe, só um
  deslocamento cromático de 0.5 no ponto do PR (cópia `primary-400` deslocada sob o ciano),
  e só no `logo-mark.svg`/inline, nunca no favicon. Fica a critério da auditoria visual.
- **Sem animação.**

Cores no inline vêm de classes Tailwind nos filhos (`stroke-primary-400`,
`fill-secondary-400`, `stroke-secondary-400`); o Tailwind v4 já varre os `.ex` do web app
(as classes atuais do `<svg>` funcionam assim). O inline deixa de depender de
`currentColor`/`text-white`; o `currentColor` fica no `logo-mark-mono.svg`.

**Mono:** as mesmas trilhas, pads como anéis e anel/ponto, tudo em `currentColor`, sem
fundo e sem as cópias de halo.

**Favicon (16–32 px):** fundo escuro `rx` 7; só dois agentes (topo e baixo) em trilhas de
45° com largura ~3 convergindo direto no pipeline, sem pads nem anel; o ponto do PR cheio
ciano `r≈4.5`; um halo largo translúcido só sob as trilhas. Mantém a leitura do favicon
atual.

## Mudanças por app

### `apps/pipe_maestro_web`

- `lib/pipe_maestro_web/components/brand_components.ex`: novo SVG de `logo_mark/1`, novas
  classes no `<svg>` (fundo escuro, ring, glow), `@moduledoc` e `@doc` reescritos. `@spec`
  igual.
- `lib/pipe_maestro_web/components/layouts.ex` (`brand/1`): **sem mudança obrigatória**.
  O ajuste do nome é opcional; a recomendação é deixá-lo como está (`text-gray-900
  dark:text-white`), que já lê bem nos dois temas e com a sidebar recolhida. Se a auditoria
  pedir, no máximo um `tracking-tight` → `tracking-normal`. Sem gradiente de texto: ele
  complica a legibilidade nos dois temas sem ganho de reconhecimento.
- `priv/static/images/logo-mark.svg`, `logo-mark-mono.svg`, `favicon.svg`: redesenhados
  (os estáticos podem usar `<defs>` para o gradiente de fundo).
- `priv/static/favicon.ico`: regerado (16/32/48 px, entradas PNG, como o atual).
- `layouts/root.html.heex`: sem mudança (já declara `favicon.svg` e `favicon.ico`).
- `assets/css/app.css`: sem mudança (paleta intacta; nada de CSS novo se as classes
  utilitárias bastarem).

### Rasterização do `favicon.ico`

Não há `rsvg-convert`, ImageMagick nem Inkscape no ambiente. O que já é dependência do
projeto e rasteriza SVG com fidelidade é o **Chromium do Playwright** (`e2e/`). Plano:

- um script `e2e/scripts/favicon.ts` (fora de `tests/` e `director/`, não entra na suíte)
  que abre o `favicon.svg` no Chromium headless, tira PNG em 16, 32 e 48 px com fundo
  transparente e empacota os três PNGs num ICO (cabeçalho `ICONDIR` + `ICONDIRENTRY`,
  poucos bytes de `Buffer`, sem dependência nova);
- um alvo `make favicon` que roda o script (`cd e2e && npx tsx`/`node --experimental-strip-types`
  conforme o que o `e2e/` já tiver; a implementação confere), com `## ...` para o
  `make help`;
- o comando fica registrado em `docs/guias/ui-petal.md` §Marca e no `e2e/README.md`.

Se o script se mostrar desproporcional, a alternativa é `brew install librsvg` e
`rsvg-convert` + empacotamento; mas instalar ferramenta na máquina não é reprodutível, então
o caminho Playwright é o recomendado. `make e2e.typecheck` deve cobrir o script novo
(`tsconfig.json` do e2e).

### `apps/pipe_maestro` (domínio)

Não muda.

### `apps/pipe_maestro_protocol`

Não muda.

### `apps/pipe_maestro_runner`

Não muda (o runner não exibe a marca).

## Fronteiras

Toda a mudança fica em `apps/pipe_maestro_web` (componente, estáticos), `e2e/` (script de
rasterização) e `docs/`. Nenhuma dependência nova entre apps; o runner continua só com
`protocol` e o domínio continua sem web.

## Protocolo

Não toca `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels.
`docs/specs/protocolo-runner.md` não muda, a versão do protocolo não sobe e runners antigos
não são afetados.

## Telas

Muda só a aparência do símbolo onde `Layouts.brand/1`/`logo_mark/1` aparecem: landing
(header e rodapé), login, seleção de workspace, ativação do runner, sidebars do app e do
backoffice. Nenhum `data-testid` novo ou alterado; nenhum componente Petal novo (a marca
é markup próprio, como já documentado em §Marca). Specs que já cobrem:

- `e2e/tests/public-pages.spec.ts` (`expectBrand`, shots `brand` e `login-brand`);
- `e2e/tests/user-session.spec.ts` (`brand` → `brand-mark` visível na sidebar).

Nenhuma spec nova é necessária; as existentes passam sem mudar seletor.

## Testes

ExUnit em `apps/pipe_maestro_web/test/pipe_maestro_web/components/brand_components_test.exs`:

- (existentes) SVG inline titulado, `viewBox`, `role`, passagem de attrs, sem
  `text`/`image`/nome de terceiros; `brand/1` com test ids, `compact`, `size`.
- **novo:** nenhum elemento com `id` no inline (`find(html, "[id]")` vazio) e nenhum
  `defs`, `filter`, `linearGradient`, `animate*` (`<animate>`, `<animateTransform>`, classe
  `animate-`).
- **novo:** classes de fundo escuro e de brilho no `<svg>` (`bg-gradient-to-br`,
  `from-primary-950`, `to-secondary-950` e a classe de glow/ring escolhida).
- **novo:** os traços usam as cores neon (`stroke-primary-400` e `secondary-400`
  presentes em filhos).
- **novo:** desenho do símbolo: três pads de agente, um anel e um ponto cheio (contagem de
  `circle` por papel, via classes ou atributos), para o significado não se perder.
- **novo (arquivos estáticos)**, no mesmo arquivo ou num `static_brand_test.exs` ao lado:
  lê `priv/static/images/*.svg` com `Application.app_dir(:pipe_maestro_web, "priv/static/...")`,
  parseia com `LazyHTML` e verifica: raiz `<svg>` com `viewBox="0 0 32 32"` e `<title>`;
  `logo-mark.svg` sem `currentColor` (autocontido); `logo-mark-mono.svg` com
  `currentColor`, sem `rect` de fundo e sem halo; `favicon.svg` com fundo; nenhum dos três
  com `<text>`/`<image>`/nome de terceiros. Para o `favicon.ico`: cabeçalho
  `<<0, 0, 1, 0, 3::little-16>>` e entradas 16/32/48 (byte de largura 16, 32, 48).

Playwright: `make e2e` (suíte inteira) e `make e2e.shots`, auditando os shots `brand`,
`login-brand` e uma tela com a sidebar (por exemplo os de `user-session`), claro e escuro:
legível em 28–32 px, halo sem estourar, marca coerente com a sidebar recolhida.
`make landing.shots` para regerar `priv/static/images/landing/*.png` (a sidebar aparece
neles).

## Documentação

- `docs/guias/ui-petal.md` §Marca: novo conceito visual (fundo escuro + neon
  primary/secondary, trilhas de circuito a 45°, pads/vias, halo por traço duplicado),
  regras (sem animação; sem ids/`<defs>` no inline; tamanho mínimo 16 px e favicon abaixo
  de 24 px; respiro de um quarto do lado; sem texto; nada de fornecedor; cores só
  primary/secondary) e o comando `make favicon` para regerar o `.ico`.
- `e2e/README.md`: uma linha sobre `make favicon` / `e2e/scripts/`.
- ADR: **não precisa**. A ADR 0019 trata do nome e da marca ser própria e agnóstica de
  fornecedor, e isso não muda; o novo estilo é uma regra de UI, que mora no guia.

## Riscos

- **Brilho no tema escuro:** quadrado escuro sobre sidebar escura some; mitigado com
  `ring` translúcido e sombra colorida no `<svg>`. Validar no shot escuro.
- **Legibilidade em 28 px:** halo largo demais borra; manter halo ≤ +2.5 de largura e
  opacidade ~0.35; testar `size-7` (sidebar/`sm`) e `size-8`.
- **Classes Tailwind em filhos do SVG** precisam aparecer literais no `.ex` (sem montar
  string), para o scanner do Tailwind v4 gerá-las.
- **`make landing.shots`** zera o banco e2e e usa o diretor com runner real; se o runner
  real não puder rodar no ambiente da etapa, registrar e regerar só o que der, sem
  inventar resultado.
- **Rasterização:** o script novo precisa passar no `make e2e.typecheck` e não entrar no
  `testDir` do Playwright.
- **Cobertura e Dialyzer:** só o componente muda; `@spec` igual, sem risco de tipo. Os
  testes novos só aumentam a cobertura do web app.
- **Migrações/dados/concorrência:** nenhum.
