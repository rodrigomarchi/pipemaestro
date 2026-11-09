# Testes que falham: qualidade das entregas no Uso

Testes escritos antes da implementação, a partir do plano (`01-plano.md`). Nenhum código de
produção mudou. Só mudaram testes, os fakes de teste e o e2e.

## O contrato que os testes fixam (para a implementação)

- `PipeMaestro.Integrations.PrOutcome` (schema). Campos: `task_id`, `workspace_id`,
  `linked_repo_id`, `pr_number`, `pr_url`, `ready_at`, `state` (`"open"`/`"merged"`/`"closed"`),
  `merged_at`, `closed_at`, `review_rounds`, `human_shas`, `pipeline_shas`, `observed_head`,
  `commits_tracked`, `commits_final`, `commits_error`.
  - `PrOutcome.classify/1` devolve `:accepted_clean | :accepted_changed | :closed | :open`.
- `PipeMaestro.Integrations.PrOutcomes`:
  - `ready(task)` devolve o desfecho, ou `nil` se a tarefa não está `succeeded` com `pr_url` e
    repositório ligado. Cria uma vez; `ready_at` não muda depois.
  - `get(task_id)` devolve o desfecho ou `nil`.
  - `observe(task_id)` devolve `:ok`, `{:error, mensagem}` (grava `commits_error`) ou `:skipped`
    (sem desfecho).
- `Provider.pr_commits/3` (GitHub e Forgejo) devolve
  `{:ok, [%{sha, parents, committed_at}]}`, do mais antigo para o mais novo, com todas as páginas.
- `get_pr/3` e `Event.pr` ganham `merged_at` e `closed_at` (lidos do host).
- `Decision.origin` (`:person | :review | :auto_merge`):
  - `correct_from_review` grava `:review`;
  - o merge automático grava `:auto_merge`;
  - o comando `corrigir` grava `:person`.
- `Conversation`:
  - `:pr_closed` sem merge passa a dar `{:processed, "pull request fechado sem integrar", …}`;
  - o mesmo review processado de novo dá `{:ignored, "review já aplicado"}`, mesmo num
    `Ingest.replay/2` (`external_id` novo, `replay:<id>:<n>`).
- `Reconciler.run/2` devolve também `outcomes:`, quantos PRs ele encontrou integrados ou
  fechados nessa passagem.
- `Usage.quality(workspace, since, filters)` devolve:
  - `total` e `by_pipeline` (`name`), com `delivered`, `accepted_clean`, `accepted_changed`,
    `closed`, `open`, `untracked`, `clean_pct`, `changed_pct`, `closed_pct`, `median_merge_ms`
    e `review_rounds_per_pr`;
  - `by_stage`, com `pipeline`, `stage` (`"correcao"` agrupa as correções, `name: "Correções"`),
    `retries`, `redone`, `decisions`, `pauses`, `review_fixes`, `merge_fixes` e `person_fixes`;
  - `top_pauses`;
  - `by_week`, com `week` (uma segunda-feira), `delivered`, `accepted_clean` e `clean_pct`.
- `UsageLive`:
  - aba `qualidade` (`usage-panel-qualidade`);
  - select `usage-project` (campo `project_id` do form `#usage-period`);
  - `data-testid` de `01-plano.md` §Telas, com `usage-quality-pipeline-<nome>`,
    `usage-quality-stage-<pipeline>-<key>-<coluna>` e `usage-quality-pause-<pipeline>-<key>`;
  - percentuais inteiros ("33%") e duração com `format_duration/1`.

### Ajustes ao plano que os testes fixam

- **A leitura final dos commits no merge e no fechamento é síncrona**, dentro de
  `Conversation.handle/3`. `Conversation` já chama o host no processamento da entrega
  (`Access.writer`, `review_comments`). Assim o critério 1 é verificável sem esperar
  processos em segundo plano. Se o host falhar, isso vai para `commits_error` e o Reconciler
  tenta de novo.
- **A chave de idempotência do review** é o `review.id` quando o host manda. Senão é o id da
  entrega original, sem o prefixo `replay:`. O webhook de review do Forgejo não traz o id do
  review.
- **O e2e não semeia pelo `Repo`**: a regra "caixa-preta" do `e2e/README.md` proíbe criar
  dados fora do navegador. O spec monta o cenário pelo fluxo real, como
  `integrations-auto-merge.spec.ts`:
  - issue no Forgejo falso → tarefa → PR;
  - commit de uma pessoa empurrado no PR, pela porta lateral nova
    `POST /__e2e/pull-commits` do Forgejo falso;
  - webhook `pull_request` mergeado.

## Arquivos

| Arquivo | O que prova |
|---|---|
| `apps/pipe_maestro/test/pipe_maestro/integrations/pr_outcomes_test.exs` (novo) | `ready_at` uma vez, inclusive pelo pipeline rodando de verdade (`Jobs.finish_job` com `delivery`); modo `runner` sem commits; critério de SHA (até a head = pipeline, depois = pessoa, merge commit ignorado); idempotência de `observe/1`; paginação; falha do host; GitHub ponta a ponta (critério 1 e 3); `classify/1` |
| `…/integrations/conversation_test.exs` | critérios 1, 2, 3 e 4 por webhook do Forgejo: commit humano + merge; review → correção `origin: :review`, uma rodada, reprocessar/replay ignorado; merge limpo; fechado sem merge; comando `corrigir` é `:person`; o mesmo merge de novo não muda nada |
| `…/integrations/forgejo_test.exs`, `github_test.exs` | `pr_commits/3` com todas as páginas, `get_pr/3` e `parse_event/2` com `merged_at`/`closed_at` |
| `…/integrations/reconciler_test.exs` | merge perdido pelo webhook achado por `get_pr/3`, com a data do host; falha do host guardada e a passagem segue |
| `…/integrations/auto_merge_test.exs` | o PR aberto pelo `Feedback` fica pronto; o merge automático grava o desfecho; correção `origin: :auto_merge` |
| `apps/pipe_maestro/test/pipe_maestro/usage/quality_test.exs` (novo) | critério 5 (retentativas, refeitas, decisões e pausas batendo com `stage_runs`/`decisions`), taxas, mediana, rodadas, semanas, critério 6 (pipeline, projeto, período) e período vazio |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/usage_live_test.exs` | aba Qualidade: estado vazio, cartões, tabelas, ranking, filtros de pipeline e projeto |
| `apps/pipe_maestro/test/support/fake_forgejo.ex`, `fake_github.ex` | `put_pull/3`, `commit_json/2` e `GET pulls/:n/commits` paginado |
| `e2e/tests/usage-quality.spec.ts`, `e2e/pages/UsagePage.ts` (novos), `e2e/helpers/fakeForgejo.ts`, `e2e/helpers/webhook.ts` | critério 7 |

## Execução

`mix format --check-formatted`: ok. `make e2e.typecheck` (`tsc --noEmit`): ok.

### Domínio (`apps/pipe_maestro`): 100 testes, 68 passam, 32 falham

```
mix test test/pipe_maestro/integrations/{pr_outcomes,conversation,forgejo,github,reconciler,auto_merge}_test.exs test/pipe_maestro/usage/quality_test.exs
Result: 68/100 passed
Failed: 32 tests
```

As 68 que passam são as vizinhas, que já existiam nos arquivos tocados. As falhas, por motivo:

- **`PrOutcomes`/`PrOutcome` não existem** (25 testes: `pr_outcomes_test`, os 6 novos de
  `conversation_test`, os 2 do `reconciler_test`, 1 do `auto_merge_test` e 4 do `quality_test`):
  ```
  ** (UndefinedFunctionError) function PipeMaestro.Integrations.PrOutcomes.ready/1 is undefined (module PipeMaestro.Integrations.PrOutcomes is not available)
  ** (UndefinedFunctionError) function PipeMaestro.Integrations.PrOutcome.__struct__/1 is undefined (module PipeMaestro.Integrations.PrOutcome is not available)
  ** (UndefinedFunctionError) function PipeMaestro.Integrations.PrOutcome.classify/1 is undefined
  ```
  O teste "the pipeline finishing…" roda as duas etapas de verdade e só então falha em
  `PrOutcomes.get/1`: o setup está certo.
- **`Usage.quality/2` não existe** (período vazio):
  ```
  ** (UndefinedFunctionError) function PipeMaestro.Usage.quality/2 is undefined or private
  ```
- **`pr_commits/3` não existe nos providers** (3 testes):
  ```
  ** (UndefinedFunctionError) function PipeMaestro.Integrations.Forgejo.pr_commits/3 is undefined or private
  ** (UndefinedFunctionError) function PipeMaestro.Integrations.GitHub.pr_commits/3 is undefined or private
  ```
- **`merged_at`/`closed_at` ainda não são lidos** (4 testes de `parse_event` e `get_pr`):
  ```
  match (=) failed
  code:  assert {:ok, %Event{pr: %{merged_at: ~U[2026-11-05 10:00:00Z]}}} =
  ```
  O mapa `pr` hoje é só `%{number, merged, head}`.
- **`Decision.origin` não existe** (o teste do merge automático que vira correção):
  `match (=) failed` em `assert [%{origin: :auto_merge}] = Tasks.list_decisions(task)`.

### Web (`apps/pipe_maestro_web`): 4 testes, 2 passam, 2 falham

```
1) test the quality tab nothing delivered says so
   Expected truthy, got false
   code: assert has_element?(view, "[data-testid=usage-panel-qualidade]:not(.hidden)")
2) test the quality tab the rates, by pipeline, …
   ** (UndefinedFunctionError) function PipeMaestro.Integrations.PrOutcome.__struct__/1 is undefined
```

A aba ainda não existe, e o cenário depende do schema novo. Os dois testes que já existiam
passam.

### e2e: `make e2e FILE=tests/usage-quality.spec.ts`, saída 2

```
✘ tests/usage-quality.spec.ts:30:7 › The quality of the deliveries › a PR a person changed before the merge is accepted with changes
Error: expect(locator).toBeVisible() failed — element(s) not found
> 52 |     await expect(this.page.getByTestId(`usage-panel-${tab}`)).toBeVisible();
    at tests/usage-quality.spec.ts:50:5
```

O spec falha no primeiro passo da tela nova: `?aba=qualidade` não tem painel. O login, o
backoffice e o workspace antes dele funcionam.

## Observação de ambiente

O Postgres de teste estava saturado por outras worktrees (`too_many_connections` no log). Os
testes rodaram mesmo assim, e os resultados acima são da execução completa.
