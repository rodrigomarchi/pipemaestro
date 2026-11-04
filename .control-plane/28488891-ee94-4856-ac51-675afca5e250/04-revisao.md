# Revisão da resolução

- Merge: `0fe2f56` (origin/main `f9e4389`, ainda atual). Correção da validação: `a137c00`.
- Base do PR original: `12f34fa` → `0d9d66b`.

## Achados

**Bloqueantes:** nenhum.

**Menores (não pedem ação):**
- `apps/pipe_maestro/lib/pipe_maestro/proposals/analysis_kind.ex`: uma linha do moduledoc reescrito ficou longa (~100 colunas). Isso é só estético: format e credo passaram.
- `apps/pipe_maestro/lib/pipe_maestro/tasks.ex:841`: o comentário cita "the budget" como motivo de pausa. O comentário se refere ao teto de custo da tarefa, que a main mantém quando configurado (ADR 0028). Não aparece em prompt e não contradiz a main.

## 1. Conflitos (`git show --remerge-diff`)
- `proposals_test.exs`: os aliases ficaram unidos (`AnalysisKind, ImproveKind, Instructions, PipelineKind`). Nenhum lado se perdeu.
- `docs/README.md`: a 0028 da main ficou intacta e a ADR do PR passou a ser **0029**.
- Ajustes semânticos que foram junto no merge: o arquivo da ADR foi renomeado para 0029 e os links em ADR 0022 e na spec da máquina de estados foram atualizados. O `AnalysisKind` perdeu `@max_budget_usd`. Os dois testes do PR que exigiam `max_budget_usd == 1` agora verificam a ausência dele. Não sobrou nenhuma referência a `0028-questionario`.

## 2. O PR continua fazendo o que fazia
Comparei, hunk por hunk, as linhas `+/-` de `git diff 12f34fa 0d9d66b` e de `git diff origin/main HEAD` (em `apps` e `e2e`). Os arquivos são os mesmos, e todas as diferenças estão explicadas:
- tirar o teto de custo do `AnalysisKind`, junto com as asserções dos testes e o moduledoc, segue a ADR 0028 da main, que tirou o teto de toda proposta e do `Kind.job_spec`;
- a união dos aliases;
- a renumeração da ADR para 0029;
- os arquivos novos do runner que vieram da validação.

Continuam lá a análise automática de falha, o questionário de decisão, a migration, a tela e os e2e do PR, além do limite de tempo de 10 min.

## 3. A main não regrediu
`git diff origin/main HEAD` nos arquivos que a main tocou só tem adições do PR. As poucas linhas `-` são mudanças que o próprio PR já fazia:
- `retry_stage` em `tasks_test`;
- comentário e ramo `[falha]` do `fake_claude`, que o PR reescreveu.

`proposals.ex` está idêntico ao da main e não voltou nenhum `max_budget`. O `fake_claude` tem os campos `max_task_cost_usd`/`max_budget_usd` da main e os ramos `[perguntas]`/`analysis` do PR. Os testes `refute_budget`/`refute_caps` da main seguem presentes e agora também cobrem o `AnalysisKind`.

## 4. Correções da validação (`a137c00`)
São legítimas. Corrigem um defeito real: o `mix test` do gate herdava `__BURRITO` e subia como o CLI do runner.
- `Application.standalone/2` só roda o CLI na VM do próprio release.
- `Shell.run` tira `__BURRITO` do ambiente.

As duas mudanças têm testes novos. Não há `@dialyzer`, `credo:disable`, skip nem exclusão de cobertura.

## 5. Migrations
O PR adiciona só `20261110090000_add_decision_questionnaire.exs`. A main não adicionou nem alterou nenhuma migration.

## Resumo para o PR
O PR #7 foi atualizado com a main (PR #8, tetos de custo) por merge:
- Nos testes, os aliases dos dois lados foram unidos.
- A ADR do questionário virou **0029**, porque a 0028 ficou com a ADR de teto de custo da main. Os links foram atualizados.
- Seguindo a ADR 0028, a análise automática (`AnalysisKind`) não tem mais teto de custo, só o limite de 10 min. Os testes dela passam a verificar a ausência do teto.
- A validação corrigiu no runner a herança de `__BURRITO` pelos comandos de gate.

`make ci` passou e o e2e passou (20/20).
