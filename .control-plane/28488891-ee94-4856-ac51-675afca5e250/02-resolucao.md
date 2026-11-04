# Merge da main e resolução dos conflitos

- HEAD antes do merge: `8b041b4` (o commit do diagnóstico, descendente de `HEAD_SHA_ORIGINAL` 0d9d66b)
- `origin/main`: `f9e438917012b10486e3a09e8e5335f2b568a696`, igual ao `BASE_SHA` (a main não avançou)
- **Merge commit: `0fe2f56349b4e693ea6e27b4b9e5069c91b22549`**: "Merge remote-tracking branch 'origin/main' into cp/resolver-conflito-do-pull-7-28488891"

## Conflitos textuais

| Arquivo | Decisão | Por quê |
|---|---|---|
| `apps/pipe_maestro/test/pipe_maestro/proposals_test.exs` | Juntei os aliases: `alias PipeMaestro.Proposals.{AnalysisKind, ImproveKind, Instructions, PipelineKind}` | O PR usa `AnalysisKind` (describe "analysis") e a main usa `Instructions` e `PipelineKind` (testes de "sem teto"). O resto do arquivo entrou por auto-merge, com os testes dos dois lados. |
| `docs/README.md` | As duas linhas no índice: 0028 "Teto de custo só quando configurado" (main) e **0029** "Questionário de decisão" (PR) | A ADR da main já está mergeada e mantém o 0028. A do PR foi renumerada. |

## Ajustes semânticos (fora dos conflitos)

| Arquivo | Decisão | Por quê |
|---|---|---|
| `docs/adr/0028-questionario-de-decisao.md` → `docs/adr/0029-questionario-de-decisao.md` | Renomeei o arquivo (`git mv`) e mudei o título para "0029 — Questionário de decisão" | Colidia com a ADR 0028 da main. |
| `docs/adr/0022-propostas-do-agente-como-mecanismo-geral.md` | Mudei o link do kind `analysis` para `[ADR 0029](0029-questionario-de-decisao.md)` | Ele apontava para a ADR do PR. A outra menção "(ADR 0028)" na linha 69 trata do teto de custo, então fica como está. |
| `docs/specs/maquina-de-estados-tarefa.md` | Mudei o link de `decision_questionnaire` para a ADR 0029 | Mesmo motivo. |
| `apps/pipe_maestro/lib/pipe_maestro/proposals/analysis_kind.ex` | Removi `@max_budget_usd 1` e `max_budget_usd:` do job e reescrevi o moduledoc ("sem teto de custo, como toda proposta") | A main (ADR 0028) tirou o teto das propostas e do tipo `Kind.job_spec`. O valor ficaria fora do contrato (risco no dialyzer) e nunca chegaria ao job. O PR continua com seu limite de tempo menor (10 min). |
| `apps/pipe_maestro/test/pipe_maestro/proposals_test.exs` ("studies the paused task…") | Troquei `max_budget_usd == 1` por `refute_budget(job)` + `refute_caps(prompt <> system_prompt)` | O teste do PR passa a seguir o comportamento combinado, com os helpers da main. |
| `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs` ("exhausted attempts…") | Troquei `max_budget_usd == 1` por `refute Map.has_key?(job.context, "max_budget_usd")` | Mesmo motivo. |

## Auto-merges conferidos

- `apps/pipe_maestro_runner/test/support/fake_claude`: tem os dois lados. A proposta de pipeline traz `max_task_cost_usd`/`max_budget_usd` (main), e os ramos `[perguntas]` e `analysis` (PR) continuam lá.
- Nenhum marcador de conflito em `apps/`, `docs/` ou `e2e/`.
- Os artefatos históricos em `.control-plane/` de outras tarefas citam "ADR 0028" para o questionário. Não mexi neles porque são registros de execuções passadas.

## Verificação feita

- `mix format` nos arquivos Elixir alterados.
- `MIX_ENV=test mix compile --warnings-as-errors`: ok.
- `mix test test/pipe_maestro/proposals_test.exs test/pipe_maestro/tasks_test.exs` (em `apps/pipe_maestro`): 102 testes, 0 falhas.

## Para a validação conferir

- `make ci` completo, com atenção ao dialyzer em `AnalysisKind.job/3` contra `Kind.job_spec` e a `job_runner_test.exs` e `proposal_live_test.exs` (auto-merge dos dois lados).
- `make e2e`: `agent-proposals.spec.ts` (PR) e `pipeline-proposal.spec.ts` (main) contra o `fake_claude` combinado.
- Que nenhum texto de prompt/questionário do PR (`Prompt`, templates) cite "orçamento/teto". Hoje só as propostas são testadas por `refute_caps`.
