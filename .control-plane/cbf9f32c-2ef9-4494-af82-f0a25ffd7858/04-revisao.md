# Revisão de convenções

Diff revisado contra `origin/main`.

## Resultado
- Plano cumprido: os critérios 1 a 8 têm código ou documentação, e testes em `proposals_test.exs`, `tasks_test.exs`, `job_runner_test.exs`, `pipeline_live_test.exs`, `proposal_live_test.exs` e `pipeline-proposal.spec.ts`.
- `@spec` e `@moduledoc`: `Pipelines.get_pipeline/2` e `Yaml.without_caps/1` têm `@spec` e `@doc`. Não há módulo novo.
- LiveViews: só textos mudaram, sem regra de negócio.
- Petal: `icon_field` com `help_text`, sem markup cru.
- `data-testid`: nenhum novo. `pipeline-max-cost` e `stage-budget-N` seguem `e2e/README.md`.
- Comentários: descrevem o código, não a mudança.
- Sem `handle_info` catch-all, sem dependência cruzando fronteira, sem exclusão de cobertura, sem contagens na prosa.
- O protocolo não mudou.

## Correção feita
- Moduledoc de `Pipelines.Stage` com linhas longas demais depois da edição: rebalanceado.

## Validação
`make ci.quick` passou (saída 0). O `make ci` completo, com Dialyzer, fica para a entrega.
