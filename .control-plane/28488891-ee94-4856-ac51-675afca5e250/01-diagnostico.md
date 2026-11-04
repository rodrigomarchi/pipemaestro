# Diagnóstico do PR

- PR: https://git.rodrigomarchi.me/rodrigomarchi/pipemaestro/pulls/7 — #7 "Tela melhor de decisão" (aberto, não mergeado, mesmo repo, mergeable=false)
- HEAD_REF: cp/tela-melhor-de-decisao-7305faf4
- HEAD_SHA_ORIGINAL: 0d9d66b11396f3fdf36637b4757b823dc8ff4ef5
- BASE_REF: main
- BASE_SHA: f9e438917012b10486e3a09e8e5335f2b568a696
- MERGE_BASE_ORIGINAL: 12f34fab1ca36c6d0efe8a6e3ab1898c695983a8

Worktree em `origin/cp/tela-melhor-de-decisao-7305faf4` (HEAD == head.sha). `origin/main` não é ancestral do HEAD.
Main ganhou só o PR #8 ("A plataforma impõe tetos de custo que ninguém pediu.", merge f9e4389).

## Conflitos (`git merge-tree`)

| Arquivo | Intenção do PR #7 | Intenção da main | PR da main |
|---|---|---|---|
| `apps/pipe_maestro/test/pipe_maestro/proposals_test.exs` | Alias `AnalysisKind` e novo `describe "analysis"` (análise automática de falha) | Alias `Instructions`, `PipelineKind`; helpers `refute_budget/1`, `refute_caps/1`, `@capped_output` e testes de "sem teto de custo" | #8 |
| `docs/README.md` | Linha do índice de ADRs: 0028 Questionário de decisão | Linha do índice: 0028 Teto de custo só quando configurado | #8 |

Resolução esperada: manter os dois lados (união dos aliases; as duas linhas de ADR, renumerando uma).

## Riscos semânticos (fora dos arquivos em conflito)

1. **Colisão de ADR 0028.** O PR cria `docs/adr/0028-questionario-de-decisao.md`; a main criou `0028-teto-de-custo-so-quando-configurado.md`. Renumerar a do PR para 0029 e atualizar as referências: `docs/README.md`, `docs/specs/maquina-de-estados-tarefa.md`, `docs/adr/0022-propostas-do-agente-como-mecanismo-geral.md` e o título do próprio ADR.
2. **Teto de custo em propostas.** A main removeu `max_budget_usd` do `Proposals.request` (`proposals.ex`, que auto-mergeia limpo), do tipo de `Kind.job` e dos kinds existentes. O PR traz `AnalysisKind` (`proposals/analysis_kind.ex`) com `@max_budget_usd 1` e `max_budget_usd:` no spec. Após o merge ele sobra fora do contrato (risco de dialyzer) e nunca chega ao contexto do job.
   - O teste do PR `proposals_test.exs` ("studies the paused task…", `job.context["max_budget_usd"] == 1`) e o de `tasks_test.exs:633` vão falhar.
   - Esses testes devem passar a esperar ausência de teto (`refute_budget/1`), e o `AnalysisKind` perde o teto, seguindo o ADR 0028 da main.
3. **Instruções/prompts sem "orçamento".** A main testa que as instruções das propostas não citam "orçamento/teto". Conferir `AnalysisKind.system_prompt`, os prompts de `Prompt`/`templates.ex` e o texto do questionário contra `refute_caps/1`.
4. **Auto-merges a revisar** (nos dois lados): `tasks_test.exs`, `job_runner_test.exs`, `proposal_live_test.exs`, `docs/adr/0022-...md` e `apps/pipe_maestro_runner/test/support/fake_claude`.
   - O `fake_claude` da main passa a devolver `max_task_cost_usd` e `max_budget_usd` na proposta de pipeline; o PR também o alterou (marcador de perguntas). Garantir que os dois marcadores sobrevivam.
   - O e2e `agent-proposals.spec.ts` do PR vs. `pipeline-proposal.spec.ts` da main (sem arquivo em comum).
5. **Migration.** O PR adiciona `20261110090000_add_decision_questionnaire.exs`. A main não adicionou migration, então não há conflito de ordem.
6. **Sem renomeações de módulos/rotas/data-testid** feitas pela main que o PR use. A main mudou só textos do form de pipeline (`pipeline_live/form.ex`, `index.ex`) e as páginas e2e `PipelinesPage.ts`.
