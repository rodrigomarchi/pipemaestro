# Telas (e2e)

A tarefa mudou o componente de marca (`brand_components.ex`) usado nas páginas públicas, além de `e2e/` (script do favicon e README).

## Execução

- `make e2e > /tmp/e2e.log 2>&1` → saída **0**, 22 testes passaram.
- `make e2e.shots FILE=tests/public-pages.spec.ts` → saída **0**.

## Telas e estados conferidos (versões clara e `-dark`)

- Marca nas páginas públicas (`01-brand`, `02-login-brand`): símbolo e nome legíveis, bom contraste e alinhamento nos dois temas.
- Landing (`01-landing`): logo no cabeçalho e no rodapé consistente com o restante da página.
- Login (`01-login-dark`): logo no canto superior esquerdo alinhado com o título, sem corte.

## Ajustes

Nenhum: nada visualmente errado, sem mudança de código nesta etapa. As screenshots são ignoradas pelo git.
