# Testes que falham: landing com screenshots reais

Os testes descrevem a landing nova (hero com o board, tour `#produto`, menu "Produto") e o
módulo `PipeMaestroWeb.LandingShots`, sem implementar nada. O diretor (`e2e/director/`,
`make landing.shots`) não ganha teste nesta etapa: ele é a ferramenta que **gera** as imagens.
Quem prova que ele rodou é o `LandingShotsTest`, que exige os 12 PNGs com o tamanho declarado.

## Arquivos

| Arquivo | O que descreve |
|---|---|
| `apps/pipe_maestro_web/test/pipe_maestro_web/controllers/landing_shots_test.exs` (novo) | `LandingShots.all/0` lista `board task decision audit usage runners`, cada uma com `title`, `text`, `alt` não vazio e `width`/`height` inteiros; `path/2` dá `/images/landing/<nome>.png` e `<nome>-dark.png`, sem "e2e", "fake" nem UUID; cada PNG, claro e escuro, existe em `priv/static`, tem as dimensões do cabeçalho IHDR iguais às declaradas e < 600 KB. |
| `apps/pipe_maestro_web/test/pipe_maestro_web/controllers/page_controller_test.exs` | `describe "the real screenshots on the landing page"`: exatamente um `hero-screenshot`, `product-tour` (com `id="produto"`) e `nav-product` (`href="#produto"`); um `tour-<nome>` dentro do tour por tela; a ordem das telas vem de `LandingShots.all/0`; toda `<img src="/images/landing/...">` do HTML existe no disco, e cada tela é referenciada em claro e escuro; o par claro/escuro usa `dark:hidden` e `hidden dark:block`; toda imagem tem `alt`, `width` e `height`, e só as do hero são `loading="eager"` (as demais `lazy`). |
| `e2e/tests/public-pages.spec.ts` | Fluxo D `[todo]`, teste "the landing page shows the real product in the hero and in the tour": `hero-screenshot` visível com a imagem do board carregada (`naturalWidth > 0`); `nav-product` leva ao `product-tour`; cada `tour-<nome>` mostra exatamente uma `<img>` visível, a clara; em escuro (mesma troca do `shot()`), a visível é a `-dark`; em 390 px, `scrollWidth - clientWidth <= 0`; `shot()` do hero e do tour no desktop e no celular. |

## Execução

### ExUnit — testes novos

```
mix test apps/pipe_maestro_web/test/pipe_maestro_web/controllers/page_controller_test.exs \
         apps/pipe_maestro_web/test/pipe_maestro_web/controllers/landing_shots_test.exs
Result: 4/13 passed
Failed: 9 tests
```

Os 4 que passam são os que já existiam (dois da landing e dois do `HealthControllerTest`).

**`LandingShotsTest` (4 testes)**: todos com

```
** (UndefinedFunctionError) function PipeMaestroWeb.LandingShots.all/0 is undefined (module PipeMaestroWeb.LandingShots is not available)
** (UndefinedFunctionError) function PipeMaestroWeb.LandingShots.path/2 is undefined (module PipeMaestroWeb.LandingShots is not available)
```

Esperado: o módulo ainda não existe. Depois de criado, os testes de arquivo só passam quando
`make landing.shots` tiver gerado os PNGs com o enquadramento declarado.

**`PageControllerTest`, os 5 novos**:

```
the hero shows the product and the tour has one block per screen
     expected exactly one hero-screenshot

the screenshots come from PipeMaestroWeb.LandingShots, one per tour block
     ** (UndefinedFunctionError) function PipeMaestroWeb.LandingShots.all/0 is undefined

every screenshot referenced by the page exists, light and dark
     the page does not reference board.png

each screenshot pair follows the dark class of the page
     code:  assert [light_class] = LazyHTML.attribute(light, "class")
     right: []

every screenshot has alt text and fixed dimensions; only the hero loads eagerly
     code: assert hero_srcs != []
     left: []
```

Esperado: a landing atual não tem hero com screenshot, tour, nem nenhuma `<img>` de
`/images/landing/`. Nenhuma falha é de sintaxe ou de setup.

### ExUnit — suíte do app web

```
mix test apps/pipe_maestro_web/test
Result: 280/289 passed
Failed: 9 tests
```

As 9 falhas são exatamente as novas acima; os testes que já existiam continuam passando.
O compilador avisa `PipeMaestroWeb.LandingShots.all/0 is undefined` nos testes novos, o que
some quando o módulo existir.

### Playwright

```
make e2e.typecheck   → exit 0 (tsc --noEmit sem erros)
make e2e FILE=tests/public-pages.spec.ts
  ✓ the landing page leads to the sign-in
  ✘ the landing page shows the real product in the hero and in the tour
  ✓ the sign-in page offers e-mail and password
  ✓ the public pages carry the PipeMaestro mark
  1 failed, 3 passed
```

Falha do teste novo:

```
Error: expect(locator).toBeVisible() failed
Locator: getByTestId('hero-screenshot')
Expected: visible
Error: element(s) not found
```

Esperado: o `hero-screenshot` ainda não existe. Os testes existentes do spec continuam verdes.

## Notas para a implementação

- O teste do controller extrai os `src` do HTML e aceita sufixo de digest
  (`/images/landing/<nome>.` e `<nome>-dark.`), para continuar valendo se a imagem passar
  pelo `~p` com digest em produção.
- O hero pode ter as duas `<img>` (claro/escuro) do board: ambas contam como `eager`.
- O spec usa `img:visible` dentro de cada bloco: o frame do navegador não pode ter outra
  `<img>` visível (os três pontos e o endereço devem ser markup, não imagem).
