# Revisão de convenções

Diff revisado: `git diff $(git merge-base HEAD origin/main)`.

## Conferido, sem achados
- `@moduledoc` e `@spec` em `LandingShots`, `PageHTML.landing_shot/1` e `PageController.home/2`.
- Sem regra de negócio em LiveView (a mudança é controller e template estático).
- `data-testid`: `nav-product`, `hero-screenshot`, `product-tour`, `tour-<nome>`, em kebab-case.
- Sem `handle_info` catch-all, sem exclusão de cobertura, sem dependência cruzando fronteira
  (o runner continua só com `protocol`; a correção em `changes.ex` tem teste).
- Comentários descrevem o código, não a mudança.
- Petal: `.badge` no tour; o frame de navegador é markup próprio, justificado no guia de UI.

## Corrigido
- Contagens na prosa: "regrava as 12 imagens" (`e2e/README.md`) e "fotografa seis telas"
  (ADR 0030) viraram texto sem número.

## Verificação
`make ci.quick` sai 0. `make ci` completo (Dialyzer) fica para a etapa de verificação.
