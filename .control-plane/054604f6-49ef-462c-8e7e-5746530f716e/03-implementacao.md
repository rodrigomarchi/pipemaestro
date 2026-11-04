# Implementação — Logo original do PipeMaestro

## O desenho

Três agentes (pontos à esquerda) convergem por curvas num único traço horizontal, o
pipeline, que passa por uma etapa (anel) e termina no pull request (ponto cheio maior).
Branco sobre um quadrado arredondado com gradiente `primary-500` (#8b5cf6) →
`secondary-500` (#0ea5e9). Sem texto, raster, fonte nem nome ou cor de fornecedor.
O favicon é uma versão simplificada (duas curvas + nó cheio, traços de 3,5) que continua
legível a 16 px (conferido no PNG rasterizado).

## O que mudou por app

### `pipe_maestro_web`
- `lib/pipe_maestro_web/components/brand_components.ex` (novo): `PipeMaestroWeb.BrandComponents.logo_mark/1`
  (`class`, `:rest` global), `<svg viewBox="0 0 32 32" role="img">` com `<title>PipeMaestro</title>`.
  O fundo com gradiente é CSS (Tailwind) no próprio `<svg>` e os traços usam `currentColor`:
  duas marcas na mesma página (nav e rodapé da landing) não disputam ids de `<linearGradient>`.
- `Layouts.brand/1`: usa `logo_mark/1` no lugar do `hero-musical-note`; `data-testid="brand"` no
  link e `data-testid="brand-mark"` no `<svg>`, que recebe `size-7`/`size-8`; `compact` continua
  pondo `pc-sidebar__brand` só no nome. API (`size`, `compact`) inalterada; não foi preciso um
  tamanho `"lg"` (os screenshots mostram a marca legível nas telas públicas).
- `priv/static/images/logo-mark.svg`, `logo-mark-mono.svg` (só `currentColor`, sem fundo) e
  `favicon.svg` (novos).
- `priv/static/favicon.ico` regenerado (16/32/48, PNG com transparência): `favicon.svg` rasterizado
  com `qlmanage` a 256 px; os cantos, que o `qlmanage` pinta de branco, foram recortados com uma
  máscara de retângulo arredondado no Pillow antes de gravar o `.ico`.
- `components/layouts/root.html.heex`: `<link rel="icon" type="image/svg+xml">` para o
  `favicon.svg` e `<link rel="icon" sizes="any">` para o `.ico`.

### `pipe_maestro`, `pipe_maestro_protocol`, `pipe_maestro_runner`
Não mudam. Protocolo intocado; runners antigos não são afetados.

### Documentação
- `docs/guias/ui-petal.md`: seção "Marca" (conceito, componentes, arquivos, regras de uso).

## Testes

Nenhum teste da etapa anterior foi alterado. Os 16 de `brand_components_test.exs` e
`static_assets_test.exs` passam, assim como os e2e novos (`public-pages`, fluxo C, e
`user-session`, fluxo A).

## Como verificar

- `mix test apps/pipe_maestro_web/test/pipe_maestro_web/components/brand_components_test.exs apps/pipe_maestro_web/test/pipe_maestro_web/controllers/static_assets_test.exs`
- `make ci.quick > /tmp/ciq.log 2>&1; echo $?` → 0
- `make ci > /tmp/ci.log 2>&1; echo $?` → 0 (com Dialyzer)
- `make e2e.shots` → 21 passed; conferidos `e2e/screenshots/public-pages/the-public-pages-carry-the-pipemaestro-mark/`
  (`01-brand`, `02-login-brand`, claro e escuro) e `user-session/one-workspace-goes-straight-to-the-board/01-board{,-dark}.png`:
  a marca fica legível nos dois temas, na landing, no login e na sidebar.

## Observações
- O texto "Powered by Claude" do rodapé da landing continua (fora do escopo, como no plano).
