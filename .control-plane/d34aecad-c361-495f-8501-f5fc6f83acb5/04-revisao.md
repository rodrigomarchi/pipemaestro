# Etapa 4 — Revisão de convenções

Diff revisado contra `origin/main`. Nada precisou de correção.

## Checklist

- **Plano cumprido:** componente, três SVGs estáticos, `favicon.ico`, `make favicon`,
  script de rasterização, guia de UI e README do e2e. Critérios 1–5 têm teste
  (`brand_components_test.exs`, `static_brand_test.exs`) e as specs e2e existentes
  cobrem os test ids.
- **`@spec`/`@moduledoc`:** `logo_mark/1` mantém `@spec`, `@doc` e `@moduledoc` atualizados;
  não há módulo Elixir novo.
- **LiveViews sem regra de negócio:** nenhuma LiveView tocada.
- **Petal antes de Tailwind:** a marca é markup próprio de SVG, como o guia já documenta.
- **`data-testid`:** nenhum novo ou alterado (`brand`, `brand-mark`, `footer-brand`,
  `footer-brand-mark` intactos).
- **Comentários:** descrevem o que o código faz (Makefile, `favicon.mts`).
- **`handle_info` catch-all, fronteiras do umbrella, exclusões de cobertura:** nada
  tocado. Só `pipe_maestro_web`, `e2e/` e `docs/` mudaram.
- **Contagens na prosa:** nenhuma no código nem nos docs do repositório.

## Verificação

`make ci.quick` → saída 0.

## Pendências (não bloqueiam)

- `make landing.shots` não rodou (precisa do diretor com runner real); os PNGs da landing
  ainda mostram o símbolo antigo na sidebar.
- `make ci` completo (Dialyzer) fica para a etapa de verificação; nenhuma `@spec` mudou.
