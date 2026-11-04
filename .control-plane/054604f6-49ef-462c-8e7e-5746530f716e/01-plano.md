# Plano — Logo original do PipeMaestro (SVG, agnóstico de agente)

Base: `origin/main` em `b3f40b8` (fast-forward feito; `git log origin/main..HEAD` vazio).

## Entendimento

Hoje a marca é `hero-musical-note` dentro de um quadrado com gradiente
(`Layouts.brand/1`, `apps/pipe_maestro_web/lib/pipe_maestro_web/components/layouts.ex`),
e não há favicon declarado no `root.html.heex` (só `priv/static/favicon.ico`, servido
por convenção). A ADR 0019 (`docs/adr/0019-o-nome-pipemaestro.md`) já fixou o produto
como "o maestro do pipeline", agnóstico de agente; o logo materializa isso.

Para quem usa: um símbolo próprio aparece na landing (nav e rodapé), nos logins do app
e do backoffice, no seletor de workspace, na ativação de runner, nas sidebars (app e
backoffice) e na aba do navegador. Nada mais muda.

### Conceito do símbolo

"Vários agentes convergindo num só fluxo, etapa por etapa, até o PR":

- Quadrado arredondado (`viewBox="0 0 32 32"`, `rx` ≈ 8) com gradiente violeta → sky
  (`primary-500` #8b5cf6 → `secondary-500` #0ea5e9), a assinatura do logo.
- Dentro, em branco: três traços curvos entrando pela esquerda em alturas diferentes
  (os agentes / as linhas de uma pauta) que convergem num único traço horizontal
  (o pipeline), com dois nós circulares (as etapas) e terminando num nó maior/cheio
  (o PR). O conjunto lembra também uma batuta riscando o ar.
- Traços grossos (stroke ≈ 2.5–3 em 32), cantos arredondados, sem texto, sem fonte,
  sem raster, poucos paths. `<title>PipeMaestro</title>` + `role="img"`.
- Nenhuma faísca/asterisco, nenhuma cor de terceiros, nenhuma palavra "Claude".

Arquivos (em `apps/pipe_maestro_web/priv/static/images/`, diretório novo; `images` já
está em `PipeMaestroWeb.static_paths/0`):

| Arquivo | Conteúdo |
|---|---|
| `logo-mark.svg` | símbolo completo, em cor (gradiente + traços brancos) |
| `logo-mark-mono.svg` | mesmo desenho, só traços em `currentColor` sem fundo (funciona sobre qualquer cor; pode ser usado sobre fundo claro ou escuro) |
| `favicon.svg` | versão simplificada para 16–32 px: duas linhas convergindo + um nó final, traços mais grossos, fundo com gradiente (mantém contraste em abas claras e escuras) |

`favicon.ico` regenerado a partir do `favicon.svg`: nesta máquina não há
`rsvg-convert`/ImageMagick/Inkscape, mas há `qlmanage` (renderiza SVG em PNG no macOS)
e Python com Pillow 12 (grava `.ico` multi-tamanho 16/32/48). Se a renderização do
`qlmanage` sair errada (fundo, transparência), plano B: rasterizar com o Chromium do
Playwright já instalado em `e2e/node_modules` via script descartável fora do repo. Se
nada servir, mantém-se o `.ico` atual e isso entra no resumo do PR.

### Critérios de aceite verificáveis

1. `GET /images/logo-mark.svg`, `/images/logo-mark-mono.svg` e `/images/favicon.svg`
   respondem 200 com `image/svg+xml` (teste ExUnit com `ConnCase`).
2. Os SVGs não contêm "claude"/"anthropic" (o mesmo teste lê os arquivos e confere,
   além de `<title>` e `viewBox` quadrado, sem `<image>` nem `@font-face`/`<text>`).
3. `brand/1` renderiza `<svg data-testid="brand-mark">` inline, o nome "PipeMaestro" e
   `data-testid="brand"` no link; não há mais `hero-musical-note` em `lib/`.
4. `compact`: o nome leva `pc-sidebar__brand` e o símbolo não (o Petal esconde só o
   nome com a sidebar recolhida).
5. `root.html.heex` declara `<link rel="icon" type="image/svg+xml" href={~p"/images/favicon.svg"}>`
   e `<link rel="icon" href={~p"/favicon.ico"} sizes="any">` (teste verifica no HTML de `/`).
6. `make e2e.shots`: marca legível em claro e escuro na landing, login e board.
7. `docs/guias/ui-petal.md` tem a seção "Marca".
8. `make ci` e `make e2e` verdes.

## Mudanças por app

### `pipe_maestro` (domínio)
**Não muda.** Nenhum contexto, schema ou migração.

### `pipe_maestro_web`
- `priv/static/images/logo-mark.svg`, `logo-mark-mono.svg`, `favicon.svg` (novos);
  `priv/static/favicon.ico` (regenerado, se possível).
- Novo `lib/pipe_maestro_web/components/brand_components.ex`
  (`PipeMaestroWeb.BrandComponents`, `@moduledoc`, `@spec`): `logo_mark/1` com attrs
  `class` e `rest` (global), desenha o SVG inline com o gradiente (o `id` do
  `<linearGradient>` precisa ser único por instância, pois a landing tem duas marcas na
  página: usar um attr `id` com default gerado, p. ex. `"brand-mark-" <> System.unique_integer`,
  ou evitar `url(#id)` desenhando o fundo com classes Tailwind num `<span>` e só os traços
  no SVG — decisão na implementação; preferência pelo segundo, que dispensa ids e herda o
  dark mode por classes).
  Um módulo próprio mantém `Layouts` enxuto; `Layouts` faz `import`/`alias` dele.
- `Layouts.brand/1`: troca o `<span>` com o Heroicon por `<.logo_mark>`; mantém attrs
  `size` (`"sm"` → `size-7`, `"md"` → `size-8`) e `compact`; acrescenta
  `data-testid="brand"` no `<.link>` e `data-testid="brand-mark"` no símbolo; o nome
  continua com `pc-sidebar__brand` quando `compact`. Avaliar um tamanho `"lg"` (`size-10`,
  `text-lg`) para as telas públicas sem nav, se o destaque pedir — sem quebrar a API.
- `components/layouts/root.html.heex`: os dois `<link rel="icon">`.
- Telas públicas (só espaçamento/tamanho, sem redesenho): `Layouts.public` (nav e
  rodapé), `LoginLive`, `Backoffice.LoginLive`, `WorkspacePickerLive`,
  `ActivateRunnerLive` — todos já chamam `Layouts.brand`; ajustar só se o screenshot
  mostrar a marca apagada.
- O texto "Powered by Claude" do rodapé fica (fora do escopo: texto da landing).

### `pipe_maestro_protocol`
**Não muda.**

### `pipe_maestro_runner`
**Não muda.**

## Fronteiras

Tudo fica em `pipe_maestro_web` (componente, assets estáticos, layout). O runner
continua dependendo só de `protocol`; o domínio continua sem web. Nenhum app novo
depende de outro.

## Protocolo

Não toca `apps/pipe_maestro_protocol`, nem o formato das mensagens dos Channels, nem
`docs/specs/protocolo-runner.md`. A versão do protocolo não sobe; runners antigos não
são afetados (nada do que trafega entre eles muda).

## Telas

Mudam visualmente (só a marca): landing, `/login`, login do backoffice, seletor de
workspace, ativação de runner, sidebars do app e do backoffice, aba do navegador.

- `data-testid` novos: `brand` (link da marca), `brand-mark` (o `<svg>`). Como a landing
  tem duas marcas (nav e rodapé), as specs usam `.first()` ou escopo do header.
- Componentes Petal: nenhum novo; o símbolo é SVG próprio (não há componente Petal de
  logo). `<.link>` continua.
- Playwright:
  - `e2e/tests/public-pages.spec.ts`: na landing e no login, `brand` e `brand-mark`
    visíveis e `shot(page.getByTestId("brand").first(), "brand")`; conferir o
    `<link rel="icon" type="image/svg+xml">` no `head`.
  - Uma spec que já abre o board (`task-pipeline.spec.ts` ou `board-alerts.spec.ts`):
    `brand-mark` visível na sidebar e `shot` da sidebar. Se o toggle de recolher do
    Petal for alcançável por test id, recolher e conferir que `brand-mark` segue visível
    e o nome some; senão, esse critério fica coberto pelo ExUnit (classe
    `pc-sidebar__brand` só no nome) e pelo screenshot.

## Testes

- `apps/pipe_maestro_web/test/pipe_maestro_web/components/brand_components_test.exs`
  (ou `layouts_test.exs`) com `Phoenix.LiveViewTest.rendered_to_string/render_component`:
  - `brand/1` renderiza `<svg` com `data-testid="brand-mark"`, `<title>`, o texto
    "PipeMaestro", `data-testid="brand"`, e não contém `hero-musical-note`;
  - `compact: true` põe `pc-sidebar__brand` no nome e não no símbolo; `compact: false` não
    põe a classe;
  - `size="sm"` vs `"md"` aplicam as classes de tamanho.
- `apps/pipe_maestro_web/test/pipe_maestro_web/controllers/static_assets_test.exs`
  (ConnCase): 200 e content-type SVG nos três arquivos; conteúdo sem "claude"/"anthropic",
  com `<title>` e sem `<image>`/`<text>`; HTML de `/` contém o `<link rel="icon"
  type="image/svg+xml" ... /images/favicon.svg>`.
- Testes LiveView existentes das telas públicas continuam passando (a marca só mudou de
  conteúdo).
- e2e conforme a seção Telas; `make e2e.shots` para auditar claro/escuro.

## Documentação

- `docs/guias/ui-petal.md`: nova seção "Marca" — conceito (maestro regendo vários
  agentes por um pipeline determinístico; agnóstico de fornecedor), os três arquivos e o
  `.ico`, o componente (`Layouts.brand/1` para marca com nome, `logo_mark/1` só o
  símbolo), regras: não recolorir com cores de terceiros nem acrescentar símbolos de
  fornecedor, gradiente só `primary`→`secondary`, mono via `currentColor`, tamanho
  mínimo 16 px (abaixo de 24 px usar o desenho do favicon), área de respiro.
- ADR: a identidade visual é decisão de produto, não de arquitetura; a ADR 0019 já
  registra o posicionamento agnóstico. **Não** crio ADR nova; o guia basta.
- Specs: nenhuma muda.

## Riscos

- **Ids de gradiente duplicados** em SVG inline (duas marcas na landing) quebram o
  `url(#...)`; mitigado desenhando o fundo com classes Tailwind e o SVG só com traços em
  `currentColor`, ou com id único por instância.
- **Legibilidade a 16 px**: por isso o `favicon.svg` simplificado; conferir renderizando
  a 16/32 px (o PNG gerado para o `.ico` serve de prova) e no screenshot da aba não dá,
  então a verificação é pelo PNG.
- **`.ico`**: dependência de ferramenta local (`qlmanage` + Pillow); plano B documentado.
- **`phx.digest` / cache**: os SVGs entram no digest do release como qualquer estático;
  `~p"/images/favicon.svg"` é verificado em compilação.
- **Cobertura/dialyzer**: componente pequeno com `@spec`; o teste novo cobre os ramos de
  `size` e `compact`. Sem migrações, dados ou concorrência envolvidos.
- **Screenshots e2e existentes** mudam de aparência (esperado); nenhuma spec seleciona
  pelo Heroicon antigo.
