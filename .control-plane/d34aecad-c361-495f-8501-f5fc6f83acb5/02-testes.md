# Etapa 2 — Testes que falham: logo cyberpunk do PipeMaestro

## O que foi escrito

Só ExUnit, em `apps/pipe_maestro_web`. Nenhuma spec Playwright nova: o plano não muda
test id nem fluxo, e `e2e/tests/public-pages.spec.ts` e `user-session.spec.ts` já cobrem a
marca (`brand`, `brand-mark`, `footer-brand*`). Por isso não houve `make e2e.typecheck`
nesta etapa.

### `test/pipe_maestro_web/components/brand_components_test.exs` (símbolo inline)

Testes novos em `describe "logo_mark/1"`:

| Teste | O que exige |
|---|---|
| shares no element ids, definitions or animation… | nenhum `[id]`, `<defs>`, `<filter>`, `<linearGradient>`, `<radialGradient>`, `<animate*>` nem classe `animate-` (guarda de regressão: já passa) |
| sits on a dark square that stands out from a dark sidebar | `<svg>` com `bg-gradient-to-br`, `from-primary-950`, `to-secondary-950`, uma classe `ring-*` e um brilho `shadow…primary` |
| draws in neon violet and cyan, not in the text color | sem `currentColor` nem `text-white`; filhos com `stroke-primary-400`, `circle.fill-secondary-400` e `circle.stroke-secondary-400` |
| traces run as circuit lines, with no curves | nenhum `path` com comando de curva (`C S Q T A`) |
| glows through a wider, translucent copy of the traces | algum filho com `opacity`/`stroke-opacity` < 1 ou classe `opacity-N` / `stroke-cor-N/NN` |
| keeps the meaning: three agent pads, one stage ring and the pull request dot | `circle.stroke-primary-400` com três `cy` distintos na mesma coluna `cx`; um anel (`stroke-secondary-400` sem `fill-secondary-400`) e o ponto (`fill-secondary-400`), em ordem `pads < anel < ponto` em `cx`, ponto com `r` maior que o anel |

### `test/pipe_maestro_web/components/static_brand_test.exs` (novo; arquivos estáticos)

Lê `priv/static/` via `Application.app_dir/2` e parseia com `LazyHTML`. Para os três SVGs,
`assert_symbol/1` verifica `viewBox="0 0 32 32"`, `<title>PipeMaestro</title>`, sem
`<text>`/`<image>`/animação/nome de terceiros.

| Teste | O que exige |
|---|---|
| `<arquivo>` draws its traces as circuit lines, with no curves (×3) | nenhum `path` com curva em `logo-mark.svg`, `logo-mark-mono.svg`, `favicon.svg` |
| logo-mark.svg is self-contained… | sem `currentColor`; cores do quadrado de fundo (fill literal ou stops do gradiente que ele referencia) com luminância relativa < 0.08; contém `#a78bfa` e `#38bdf8` |
| logo-mark.svg glows through translucent copies… | sem `<filter>`; algum `opacity`/`stroke-opacity` fracionário |
| logo-mark-mono.svg draws only in currentColor… | `currentColor`, nenhuma cor hex, nenhum `url(`, nenhuma `opacity`, nenhum `rect` (guarda: já passa) |
| logo-mark-mono.svg keeps the three agent pads… | ao menos cinco `circle` (guarda: já passa) |
| favicon.svg is the simplified symbol on a dark square… | sem `currentColor`; fundo escuro; contém `#38bdf8` |
| favicon.ico carries 16, 32 and 48 px PNG entries | cabeçalho ICO com entradas 16/32/48 (guarda: já passa) |
| favicon.ico is rasterized from the dark favicon | decodifica o PNG de 32 px (RGBA 8 bits, `:zlib` + desfiltro PNG no próprio teste) e exige o pixel (16, 3), fundo do quadrado, opaco e com luminância < 0.08 |

## Execução

`mix format` rodado. `mix credo --strict` sem problemas.

```
mix test apps/pipe_maestro_web/test/pipe_maestro_web/components/brand_components_test.exs \
         apps/pipe_maestro_web/test/pipe_maestro_web/components/static_brand_test.exs
Result: 13/25 passed
Failed: 12 tests
```

Suíte inteira do web app (`cd apps/pipe_maestro_web && mix test`): `303/315 passed`, e as
12 falhas são exatamente os testes novos abaixo. Os testes que já existiam continuam
passando.

### Falhas e por que são as esperadas

1. **inline — dark square**
   ```
   Assertion with in failed
   code:  assert "from-primary-950" in svg_classes
   right: ["shrink-0", "rounded-lg", "bg-gradient-to-br", "from-primary-500", "to-secondary-500", "text-white", "shadow-sm"]
   ```
   O `<svg>` ainda tem o gradiente claro `primary-500 → secondary-500`.
2. **inline — neon, not text color**
   ```
   Refute with =~ failed
   code:  refute html =~ "currentColor"
   ```
   Os traços ainda seguem `currentColor` (branco via `text-white`).
3. **inline — no curves**
   ```
   curved path: M7 9.5C11 9.5 12 16 16 16M7 22.5C11 22.5 12 16 16 16M7 16H21.5
   ```
   O desenho atual usa Béziers; o novo usa trilhas retas com cantos a 45°.
4. **inline — glow**
   ```
   Expected truthy, got false
   code: assert html |> find("svg *") |> Enum.any?(&translucent?/1)
   ```
   Ainda não existe a cópia translúcida dos traços.
5. **inline — meaning**
   ```
   code:  assert [{pad_x, _} | _] = pads
   ```
   Nenhum `circle.stroke-primary-400`: os pads hoje são pontos cheios em `currentColor`.
6. **logo-mark.svg — no curves**, 7. **logo-mark-mono.svg — no curves**, 8. **favicon.svg — no curves**
   ```
   curved path: M7 9.5C11 9.5 12 16 16 16M7 22.5C11 22.5 12 16 16 16M7 16H21.5
   curved path: M7 8.5C12 8.5 12.5 16 17 16M7 23.5C12 23.5 12.5 16 17 16H20
   ```
   Os estáticos ainda têm o desenho curvo.
9. **logo-mark.svg — self-contained, dark** e 10. **favicon.svg — dark square**
   ```
   #8b5cf6 is not dark
   code: for color <- background_colors(doc),
   ```
   O fundo ainda é o gradiente `#8b5cf6 → #0ea5e9`.
11. **logo-mark.svg — glow**
   ```
   Assertion with =~ failed
   code:  assert source =~ ~r/(stroke-)?opacity="0?\.\d+"/
   ```
   Sem halo translúcido no estático.
12. **favicon.ico — rasterized from the dark favicon**
   ```
   background pixel {100, 115, 242} is not dark
   ```
   O `.ico` atual é o rasterizado do favicon com gradiente claro (o pixel decodificado é o
   violeta-azul do gradiente), o que também confirma que o decodificador de PNG do teste
   funciona sobre o arquivo real.

## Notas para a implementação

- As classes dos filhos do SVG inline que os testes procuram (`stroke-primary-400`,
  `fill-secondary-400`, `stroke-secondary-400`) precisam aparecer literais no `.ex`.
- O halo inline pode ser `stroke-opacity="0.35"`/`opacity` ou classe com alfa
  (`stroke-primary-400/35`, `opacity-35`); o teste aceita qualquer um.
- No `favicon.svg`, o pixel (16, 3) em 32 px tem de ser fundo do quadrado (sem trilha nem
  halo ali); o desenho do plano (trilhas a partir de y≈8) atende.
- O quadrado de fundo dos estáticos é localizado por `rect[width="32"][height="32"]`.
