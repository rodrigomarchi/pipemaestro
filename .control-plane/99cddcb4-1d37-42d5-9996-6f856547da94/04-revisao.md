# 04 — Revisão de convenções

Diff revisado contra `origin/main`.

## Resultado

- Plano cumprido: pipeline no pedido, auto-aprovação no fim do job, idempotência por
  `tasks.proposal_job_id` (índice único parcial), link para a tarefa criada, motivo guardado
  quando não cria. Os critérios de aceite têm teste (domínio, LiveView e e2e).
- `@spec`/`@moduledoc`: presentes em tudo o que é novo (`create_task/4`, `created_task_id/1`,
  `auto_approve/1`, `job_finished/1`, `update_proposal/2`).
- LiveViews finas: `ProposalLive.Show` e `TaskLive.Index` só delegam a `Proposals`/`Tasks`.
- Petal: `icon_field type="select"`, `field type="switch"`, `alert`, `button`; sem Tailwind cru novo.
- `data-testid` presentes em tudo o que os testes tocam, em kebab-case.
- Sem `handle_info` catch-all novo, sem dependência cruzando fronteira, sem exclusão de
  cobertura, sem contagem em prosa, protocolo intocado.

## Correção feita

- `e2e/tests/agent-proposals.spec.ts`: fluxos D e E estavam `[todo]` no cabeçalho `@flow`
  apesar de implementados e passando; agora `[done]`.

## Validação

`make ci.quick` sai 0. Dialyzer e `make e2e.shots` já passaram na etapa 3.
