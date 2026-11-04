# Etapa 2 — Testes que falham: "Últimas execuções" na página do runner

## Mínimo para compilar

`apps/pipe_maestro/lib/pipe_maestro/jobs.ex`: stub
`Jobs.recent_for_runner(Workspace.t(), Runner.t(), pos_integer()) :: [Job.t()]` com `@doc`
e `@spec`, `limit \\ 10`, que por enquanto devolve `[]`. Sem isso, as chamadas virariam
`UndefinedFunctionError` em vez de falhas de asserção. A `RunnerLive` não mudou.

## Testes criados

### Domínio — `apps/pipe_maestro/test/pipe_maestro/jobs_test.exs`

`describe "recent_for_runner/3"` (helpers `run_and_finish/4` e `pin_finished_at/2`, que fixam
um `finished_at` diferente para cada job porque a coluna tem resolução de segundo):

| Teste | Critério |
|---|---|
| the jobs the runner finished, latest first, without active or never-started ones | CA2: ordem `finished_at desc`; na fila, em execução e cancelado antes de começar ficam de fora |
| at most ten by default, the most recent ones | CA2: 12 terminados → as 10 mais recentes; `limit` explícito respeitado |
| a job the runner lost when it restarted counts as finished | job falho por `reconcile/2` entra |
| only this workspace's jobs on this runner | CA7: outro runner do workspace e runner de outro workspace ficam de fora; workspace errado → `[]` |
| a stage's job comes with its stage and task | CA3 (dado): `stage_run.task` pré-carregado |

### LiveView — `apps/pipe_maestro_web/test/pipe_maestro_web/live/runner_live_test.exs`

`describe "latest jobs"`:

| Teste | Critério |
|---|---|
| a runner that has not finished any job says so | CA1, CA5: `runner-recent-jobs` com "Últimas execuções"; `runner-no-recent-jobs` com "Este runner ainda não terminou nenhuma execução." |
| a job the runner finishes shows up live with its numbers | CA6, CA3, CA2: enquanto está rodando, o job fica só em `runner-job-*`; depois do `finish_job`, a linha aparece sem novo `live/2`, com link "investigue o login", "Concluído", "1 s", "US$ 0.0042", "3.5k" tokens e "97%" de cache; o estado vazio some |
| a job that failed without numbers shows dashes | CA3: "Falhou" e "—" em duração, custo, tokens e cache |
| a stage's job shows its task and stage instead of the prompt | CA3: "Corrigir login · Etapa A" |
| each job leads to its page | CA4: o clique em `runner-recent-job-link-{id}` faz `live_redirect` para `/w/:slug/jobs/:id` |
| another runner's finished job is not listed | CA7: o job terminado de outro runner do workspace não aparece; o estado vazio continua |

Os test ids usados são os do plano: `runner-recent-jobs`, `runner-no-recent-jobs`,
`runner-recent-job-{id}`, `runner-recent-job-link-{id}`, `runner-recent-job-status-{id}`,
`-duration-`, `-cost-`, `-tokens-`, `-cache-`.

O e2e (`runner-connection.spec.ts`, CA8) fica para a implementação, junto com o page object,
como prevê o plano: depende do card já renderizado e do runner real.

## Execução

### Domínio

```
$ cd apps/pipe_maestro && mix test test/pipe_maestro/jobs_test.exs
Running ExUnit with seed: 182464, max_cases: 28

  1) test recent_for_runner/3 only this workspace's jobs on this runner (PipeMaestro.JobsTest)
     match (=) failed
     code:  assert [%Job{id: id}] = Jobs.recent_for_runner(ctx.workspace, ctx.runner)
     right: []

  2) test recent_for_runner/3 the jobs the runner finished, latest first, without active or never-started ones
     Assertion with == failed
     left:  []
     right: [{"a439e31b-…", :failed}, {"7beda4c0-…", :canceled}, {"3805f3f0-…", :succeeded}]

  3) test recent_for_runner/3 a stage's job comes with its stage and task
     match (=) failed
     right: []

  4) test recent_for_runner/3 at most ten by default, the most recent ones
     Assertion with == failed
     left:  []
     right: [ten ids]

  5) test recent_for_runner/3 a job the runner lost when it restarted counts as finished
     match (=) failed
     right: []

Result: 16/21 passed
Failed: 5 tests
```

Os cinco novos falham porque o stub devolve `[]`; os testes existentes seguem verdes.

### LiveView

```
$ cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/live/runner_live_test.exs
  1) test latest jobs a runner that has not finished any job says so
     code: assert has_element?(view, "[data-testid=runner-recent-jobs]", "Últimas execuções")
  2) test latest jobs a job that failed without numbers shows dashes
     code: assert has_element?(view, "[data-testid=runner-recent-job-status-#{job.id}]", "Falhou")
  3) test latest jobs a stage's job shows its task and stage instead of the prompt
     code: assert has_element?(view, "[data-testid=runner-recent-job-link-#{job.id}]", "Corrigir login · Etapa A")
  4) test latest jobs a job the runner finishes shows up live with its numbers
     code: assert has_element?(view, row)
  5) test latest jobs another runner's finished job is not listed
     code: assert has_element?(view, "[data-testid=runner-no-recent-jobs]")
  6) test latest jobs each job leads to its page
     code: |> render_click()   (o seletor do link não encontra elemento)
Result: 3/9 passed
Failed: 6 tests
```

Os seis novos falham porque o card "Últimas execuções" ainda não existe na página; os três
testes existentes da `RunnerLive` seguem verdes. Nenhuma falha vem de compilação ou setup:
as fixtures (jobs, tarefa de pipeline, outro runner) são criadas e os jobs terminam.
