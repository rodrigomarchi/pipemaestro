# Implementação: a plataforma impõe tetos de custo que ninguém pediu

O plano (`01-plano.md`) foi implementado como estava. Os testes da etapa 2 passam, e só um
deles mudou, explicado abaixo.

## O que mudou, por app

### `apps/pipe_maestro` (domínio)
- `Proposals.Kind`: o `job_spec` não tem mais `max_budget_usd`.
- `Proposals.request/5`: o contexto do job vai sem `"max_budget_usd"` (no fio, `nil`).
- `TaskKind`, `DecisionKind`, `PipelineKind`, `ImproveKind`: o `job/3` não fixa mais o
  orçamento. O `timeout_ms` continua.
- `PipelineKind.pipeline_schema/0` (que o `ImproveKind` também usa): sem `max_task_cost_usd`.
- `Pipelines.Yaml.without_caps/1` (nova): tira `max_task_cost_usd` dos atributos e
  `max_budget_usd` de cada etapa. `PipelineKind.result/2` e `ImproveKind.result/2` a
  aplicam depois de `from_map/1`. A importação de YAML pela pessoa não muda.
- `ImproveKind`:
  - o YAML do prompt vai sem tetos (`uncapped/1`);
  - o resultado recoloca o teto *atual* do pipeline e o de cada etapa cuja `key` continua,
    em texto (`with_caps_of/2`);
  - pipeline apagado: sem tetos.
- `Pipelines.get_pipeline/2` (nova): recebe o `workspace_id` e o `id` e devolve `nil` se o
  pipeline não estiver lá. A busca é escopada ao workspace do job.
- `Proposals.Instructions.pipeline_format/0`: "só uma regra ou uma falha param a tarefa".
- Moduledocs de `Pipeline` e `Stage`: o teto só existe quando a pessoa o configura.
- `Tasks`: sem mudança, e não há migração.

### `apps/pipe_maestro_web`
- `PipelineLive.Form`:
  - rótulo "Teto de custo por tarefa (US$, opcional)", com a ajuda "Vazio é sem limite.
    Com um valor, a tarefa para e pede uma decisão ao passar dele.";
  - na etapa, "Teto de custo (US$, opcional)", com a ajuda "Vazio é sem limite.";
  - a descrição da seção Execução passa a ser "Um teto de custo, se quiser, e o que vira
    do código.".
- `PipelineLive.Index`: "Sem limite de custo".
- Nenhum `data-testid` novo e nenhum markup novo: é o `icon_field` com `help_text`.

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`
Sem mudança de código. Um runner antigo é compatível, porque já omite
`--max-budget-usd` quando o campo vem `nil`. O teste de regressão do runner é da etapa 2.

### Documentação e e2e
- Nova ADR `docs/adr/0028-teto-de-custo-so-quando-configurado.md`, com a entrada no
  índice de `docs/README.md`.
- ADRs 0011, 0021 e 0022 atualizadas.
- `docs/specs/protocolo-runner.md` (`max_budget_usd`) e `docs/plano/01-visao-arquitetura.md`
  (tabela) atualizados.
- `e2e/tests/pipeline-proposal.spec.ts`: o fluxo C passou a `[done]`.

## Teste corrigido
Em `proposals_test.exs`, "keeps the pipeline's own caps, which the agent never sees" usava
um pipeline chamado **"Com teto"**. O nome do pipeline vai ao prompt (título e YAML), e o
`refute_caps/1` (`\bteto`) acusava o nome escolhido pelo próprio teste, não um teto. O
pipeline passou a se chamar "Limitado". As asserções continuam as mesmas.

## Como verificar
- `make ci.quick > /tmp/ciq.log 2>&1; echo $?` → `0`.
- `make e2e FILE=tests/pipeline-proposal.spec.ts` → passa (o fluxo C inclusive).
- `make e2e.shots` → 17 passaram. Conferidos:
  - `pipeline-proposal/.../04-proposal-pipeline-form*.png`: os tetos estão vazios e os
    textos dizem "Vazio é sem limite";
  - `task-pipeline/.../02-pipelines*.png`: "Sem limite de custo".
- Alvos rápidos:
  - `cd apps/pipe_maestro && mix test test/pipe_maestro/proposals_test.exs test/pipe_maestro/tasks_test.exs`
  - `cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/live/pipeline_live_test.exs test/pipe_maestro_web/live/proposal_live_test.exs`

## Para a entrega
Os pipelines que já nasceram com um teto proposto pelo agente (por exemplo, o "Evolução do
PipeMaestro", com US$ 40) mantêm esse teto até a pessoa apagá-lo no formulário.
`make ci` completo (com Dialyzer) fica para o fim do bloco.
