# Testes que falham — Logo original do PipeMaestro

## O que foi escrito

### ExUnit (`apps/pipe_maestro_web`)

`test/pipe_maestro_web/components/brand_components_test.exs` (`ExUnit.Case` +
`render_component`, no padrão de `job_components_test.exs`):

- `BrandComponents.logo_mark/1`: `<svg>` inline com `role="img"`, `<title>PipeMaestro</title>`,
  `viewBox="0 0 32 32"` e a `class` recebida; repassa atributos globais (`data-testid`);
  sem `<text>`, `<image>` nem "claude"/"anthropic".
- `Layouts.brand/1`: `<a data-testid="brand" href="/">` com um `svg[data-testid="brand-mark"]`
  e o nome; sem `hero-musical-note`; com `compact`, `pc-sidebar__brand` fica só no nome e
  não no símbolo; sem `compact`, a classe não aparece; `size="sm"` → `size-7` e `"md"` → `size-8`
  no `<svg>`.

`test/pipe_maestro_web/controllers/static_assets_test.exs` (`ConnCase`):

- `GET /images/{logo-mark,logo-mark-mono,favicon}.svg` → 200, `image/svg+xml`.
- Cada arquivo: `viewBox="0 0 32 32"`, `<title>PipeMaestro</title>`, sem `<image`, `<text`,
  `@font-face` nem "claude"/"anthropic"; o mono usa `currentColor`.
- O `<head>` de `/` declara `link[rel=icon][type=image/svg+xml]` → `/images/favicon(-digest).svg`
  e `link[rel=icon][sizes=any]` → `/favicon(-digest).ico`.

### Playwright (`e2e/tests`)

- `public-pages.spec.ts`: novo teste/fluxo C `[todo]`, "the public pages carry the PipeMaestro
  mark". Na landing e no `/login`, `brand` (o `.first()`, porque a landing tem marca no nav e no
  rodapé) fica visível com "PipeMaestro" e um `brand-mark` dentro; tira os shots `brand` e
  `login-brand`. O `<link rel="icon">` do `<head>` não tem test id, então quem cobre o favicon
  é o ExUnit, e o spec continua só com `getByTestId`.
- `user-session.spec.ts`, fluxo A: no board, `brand` → `brand-mark` visível na sidebar, antes
  do shot `board`.

`make e2e.typecheck` → exit 0 (o spec compila). Quando rodar, ele falha pelo motivo certo: hoje
não existe nenhum elemento `data-testid="brand"`/`"brand-mark"`, e o `toBeVisible` estoura o
timeout. A suíte e2e não foi rodada, como pede a etapa.

## Falhas (motivo certo)

`mix test apps/pipe_maestro_web/test/pipe_maestro_web/components/brand_components_test.exs apps/pipe_maestro_web/test/pipe_maestro_web/controllers/static_assets_test.exs`
→ `Result: 1/16 passed — Failed: 15 tests`.

| Teste | Falha | Por que é a esperada |
|---|---|---|
| `logo_mark/1` (3 testes) | `** (UndefinedFunctionError) function PipeMaestroWeb.BrandComponents.logo_mark/1 is undefined (module PipeMaestroWeb.BrandComponents is not available)` | O componente ainda não existe. O compilador também avisa "undefined module" no teste, e isso some quando o módulo for criado. |
| `brand/1 links home with the symbol and the name` | `expected one a[data-testid="brand"]`, em `code: link = one!(html, ~s(a[data-testid="brand"]))` | O link atual não tem `data-testid`. |
| `brand/1 no longer uses the generic musical note icon` | `refute ... =~ "hero-musical-note"`, e o `left:` mostra `<span phx-r class="hero-musical-note size-5">` | A marca atual ainda é o Heroicon. |
| `brand/1 compact hides only the name…` | falha em `one!(html, ~s(svg[data-testid="brand-mark"]))` | Ainda não há `<svg>` de marca (o nome já tem `pc-sidebar__brand`). |
| `brand/1 sizes the symbol…` | falha em `one!(sm, ~s(svg[data-testid="brand-mark"]))` | Idem: o tamanho fica num `<span>`, não há `<svg>`. |
| `GET /images/*.svg` (3) | `Assertion with == failed — code: assert conn.status == 200 — left: 404` | Os arquivos ainda não existem em `priv/static/images/`. |
| conteúdo dos SVGs (3) + mono `currentColor` | `** (File.Error) could not read file ".../priv/static/images/logo-mark.svg": no such file or directory` | Idem. |
| favicon no `<head>` | `code: assert [href] = LazyHTML.attribute(svg_icon, "href")`, com `[]` à direita | O `root.html.heex` não declara nenhum `<link rel="icon">`. |

O que passa: `brand/1 is not compact by default`. Ele guarda um comportamento que já existe
(o nome sem `pc-sidebar__brand`) e serve de proteção contra regressão.

## Testes existentes

`cd apps/pipe_maestro_web && mix test` → `Result: 264/279 passed — Failed: 15 tests`. As 15
falhas são exatamente as novas, listadas acima; os testes que já existiam passam todos.

## Observações para a implementação

- Os seletores dos testes fixam: `data-testid="brand"` no `<.link>`, `data-testid="brand-mark"`
  **no `<svg>`** (não num `<span>` em volta), e a classe de tamanho (`size-7`/`size-8`) também
  no `<svg>`. Se o fundo com gradiente for um `<span>` Tailwind (opção preferida no plano), o
  `<svg>` precisa receber o mesmo `size-*` (p. ex. `size-full` não basta) ou o teste será
  ajustado na implementação, de forma justificada.
- `logo_mark/1` deve aceitar `class` e atributos globais (`:rest`), e ter `viewBox="0 0 32 32"`,
  `role="img"` e `<title>PipeMaestro</title>`.
