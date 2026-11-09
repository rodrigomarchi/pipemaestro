# Plano: ajuste por pipeline para ligar ou desligar a análise automática

Branch `cp/ajuste-por-pipeline-para-ligar-ou-deslig-07563240`, partindo de `origin/main` (`225fdfd`, sem commits de outras tarefas).

## Entendimento

Hoje, quando uma etapa falha (tentativas esgotadas, gate reprovado, erro do CLI) ou bloqueia sem nada a perguntar, `PipeMaestro.Tasks.await/3` pausa a tarefa e chama `request_analysis/1`. Essa função pede uma proposta `analysis` (`PipeMaestro.Proposals.AnalysisKind`), que custa até US$ 1. O ADR 0029 (§Consequências) deixou "um ajuste por pipeline para desligá-la" para depois.

Para quem usa:

- O drawer do pipeline, na aba **Entrega**, ganha o switch **"Analisar falhas com IA"**, ligado por padrão.
- Com o switch desligado, a pausa por falha mostra só o motivo e a decisão manual: Refazer, Seguir com instruções, Cancelar e "Sugerir com IA", que continua sob demanda.
- Pipelines e tarefas que já existem não mudam.

Critérios de aceite verificáveis (iguais aos da tarefa):

1. Ajuste desligado + gate reprovado até esgotar: a tarefa fica em `awaiting_decision` com `decision_reason`, `decision_questionnaire: nil` e `decision_analysis_job_id: nil`, e nenhum `Job` de proposta `analysis` com `task_id` da tarefa.
2. Ajuste desligado + bloqueio sem perguntas (etapa única e grupo paralelo): pausa sem análise. Bloqueio com perguntas: o questionário do agente aparece como hoje.
3. Ajuste ligado, ou `pipeline_context` sem a chave ou `nil`: a análise é pedida como hoje.
4. `Pipeline.context/1` traz `"auto_analysis"`. Desligar o ajuste no pipeline depois de criar a tarefa não muda essa tarefa.
5. O YAML escreve `auto_analysis: false` só quando o ajuste está desligado, e a ida e volta preserva o valor. Um YAML sem a chave importa ligado. `without_caps/1` mantém a chave.
6. O drawer tem o switch na aba Entrega, salva o valor e o reabre com o valor salvo. O resumo do pipeline avisa quando a análise está desligada.
7. Tela da tarefa pausada com o ajuste desligado: motivo, Refazer, Seguir, Cancelar e "Sugerir com IA" visíveis, nenhum indicador de análise.
8. e2e e capturas claro e escuro do drawer; docs; `@spec`/`@moduledoc`; `make ci` verde.

## Nome do campo

**`auto_analysis`** (booleano, `default: true`, `null: false`), com a chave `"auto_analysis"` no retrato. Ele segue o padrão de `auto_merge`, que já existe ao lado.

## Mudanças por app

### `apps/pipe_maestro` (domínio)

- **Migração nova** `priv/repo/migrations/20261124100000_add_auto_analysis_to_pipelines.exs`, com timestamp depois de `20261123100000_add_session_totals_to_jobs.exs`. Ela faz `alter table(:pipelines) do add :auto_analysis, :boolean, null: false, default: true end`. As linhas que já existem ficam `true`. Nenhum backfill de `tasks.pipeline_context`, porque a ausência da chave conta como ligado.
- **`PipeMaestro.Pipelines.Pipeline`** (`lib/pipe_maestro/pipelines/pipeline.ex`):
  - `field :auto_analysis, :boolean, default: true`, mais `auto_analysis: boolean()` no `@type t` e `:auto_analysis` no `cast` de `changeset/2`;
  - `context/1` inclui `"auto_analysis" => pipeline.auto_analysis`;
  - o `@moduledoc` descreve o campo: com ele ligado, cada pausa por falha ou bloqueio sem perguntas pede ao agente uma análise (até US$ 1, `AnalysisKind`); com ele desligado, a pausa leva só o motivo.
- **`PipeMaestro.Tasks`** (`lib/pipe_maestro/tasks.ex`):
  - Em `await/3`, troco `if asking == :analysis, do: request_analysis(task), else: task` por `if asking == :analysis and auto_analysis?(task), do: …`.
  - O helper privado é `defp auto_analysis?(task), do: context(task, "auto_analysis") != false`. Ele reaproveita `context/2` (linha ~861), que já devolve `nil` para `pipeline_context: nil`, então `nil` e a chave ausente contam como ligado.
  - O ponto único cobre `{:exhausted, _}`, `asking(nil)` e `group_asking/1`. `asking/1` e `group_asking/1` não mudam: um bloqueio com perguntas continua `{:questionnaire, _}`.
  - Atualizo o comentário de `await/3` e o `@moduledoc` ("a failure … an analysis the platform asks … when the pipeline has `auto_analysis` on").
  - `request_analysis/1` continua público e sem condição.
- **`PipeMaestro.Pipelines.Yaml`** (`lib/pipe_maestro/pipelines/yaml.ex`):
  - na lista `top` de `to_yaml/1` entra `{"auto_analysis", if(pipeline.auto_analysis, do: nil, else: false)}`. `fields/2` descarta só `nil`, `""` e `[]`, então `false` é escrito;
  - `"auto_analysis"` entra no `Map.take` de `from_map/1`;
  - `without_caps/1` não muda. O `@doc` de `without_caps/1` ganha a frase "`auto_analysis` stays: turning it off only lowers cost".
- **`PipeMaestro.Proposals.ImproveKind`** (`lib/pipe_maestro/proposals/improve_kind.ex`): `with_caps_of/2` passa a manter o `auto_analysis` atual do pipeline, como `merge_settings/1` já faz com o merge. Ligar ou desligar a análise é escolha de uma pessoa, e uma melhoria proposta pelo agente não deve religá-la (o que voltaria a gastar) nem desligá-la sem pedido. É um detalhe de coerência que a tarefa não cita; vale `Map.put(attrs, "auto_analysis", pipeline.auto_analysis)`. `PipelineKind` (pipeline novo gerado pelo agente) aceita o que vier, com padrão ligado.
- **Templates** (`Pipelines.Templates`): não mudam, porque herdam o padrão ligado.

### `apps/pipe_maestro_web`

- **`PipeMaestroWeb.PipelineLive.FormFields`** (`live/pipeline_live/form_fields.ex`):
  - a aba `"entrega"` de `@entry_tabs` passa a listar `[:max_task_cost_usd, :auto_analysis, :delivery, …]`;
  - em `execution_fields/1`, logo depois do teto de custo, entra `<.field field={@form[:auto_analysis]} type="switch" label="Analisar falhas com IA" help_text="Cada pausa por falha pede ao agente um diagnóstico e perguntas (até US$ 1). Desligado, a tarefa pausa só com o erro." data-testid="pipeline-auto-analysis" />`, no mesmo idioma do switch `pipeline-auto-merge`;
  - antes, confiro em `docs/guias/ui-petal.md` se o `field` de tipo switch aceita `help_text`. Se não aceitar, uso um `<p data-testid="pipeline-auto-analysis-help">` como em `pipeline-auto-merge-help`.
- **`PipeMaestroWeb.PipelineComponents`** (`components/pipeline_components.ex`, bloco `<dl>` com "Merge sozinha", linha ~1035): `<div :if={!@pipeline.auto_analysis} data-testid="pipeline-summary-no-analysis">` com o ícone `hero-sparkles` (ou similar) e o texto "Sem análise automática de falhas". Só aparece quando a análise está desligada, para não poluir o caso padrão.
- **`TaskLive.DecisionPanel` e `DecisionsLive`**: não mudam. Com `decision_analysis_job_id: nil`, `Tasks.questionnaire/1` já devolve `analysis: :none`, `analysis_state` não renderiza aviso e a decisão manual abre (`open={is_nil(questionnaire) and analysis != :running}`). Isso fica provado por teste.
- **Channels**: não mudam.

### `apps/pipe_maestro_protocol`

Não muda.

### `apps/pipe_maestro_runner`

Não muda.

## Fronteiras

Toda a mudança fica no domínio (schema, contexto, YAML, proposta) e na web (form e componente). O domínio não ganha nada de web. O runner continua dependendo só de `protocol` e nada passa a depender dele. Nenhuma dependência nova entre apps.

## Protocolo

A mudança **não toca** `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels. A análise é uma proposta já existente, e o ajuste só decide, no control plane, se ela é pedida.

- `docs/specs/protocolo-runner.md` não muda.
- A versão do protocolo não sobe.
- Runners antigos continuam compatíveis: não percebem diferença, apenas deixam de receber jobs `analysis` dos pipelines com o ajuste desligado.

## Telas

- **Drawer do pipeline**, aba Entrega: switch `data-testid="pipeline-auto-analysis"` (e `pipeline-auto-analysis-help`, se a ajuda for um `<p>` à parte). Componente Petal `<.field type="switch">`, o mesmo do `pipeline-auto-merge`.
- **Resumo do pipeline**: `data-testid="pipeline-summary-no-analysis"`, só quando desligado.
- **Pausa da tarefa** (`TaskLive.DecisionPanel`, `DecisionsLive`): nenhuma mudança de markup. O caso `analysis: :none` já existe.
- **Playwright**: spec novo `e2e/tests/pipeline-auto-analysis.spec.ts`, com o cabeçalho `@section`/`@flow` dos outros specs. Ele:
  - entra num workspace com os pipelines prontos (`PipelinesPage.createDefaults`) e abre um pipeline (`edit`, `openEntry`, `openEntryTab("entrega")`);
  - confere o switch ligado, desliga, salva, reabre e confere desligado e o resumo `pipeline-summary-no-analysis`;
  - tira `shot(...)` do drawer na aba Entrega.

  Não precisa de runner. Se `setUp` em `decision-questionnaire.spec.ts` ou `integrations-auto-merge.spec.ts` já tiver um caminho mais curto até o drawer, reaproveito. Rodo `make e2e FILE=tests/pipeline-auto-analysis.spec.ts` e `make e2e.shots FILE=tests/pipeline-auto-analysis.spec.ts` (claro e escuro), copio as capturas para `$CP_FILES_DIR` e audito.

## Testes

| Critério | Teste |
|---|---|
| 1 | `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs`, no `describe` da análise (perto da linha 618, `analysis_job/2`): pipeline com `auto_analysis: false`, gate reprovado até esgotar. Afirma `awaiting_decision`, `decision_reason`, `decision_analysis_job_id == nil`, `decision_questionnaire == nil`, `Tasks.questionnaire(task) == %{questionnaire: nil, analysis: :none}` e que nenhum `Job` com `Proposals.kind(job) == "analysis"` e `input["task_id"] == task.id` existe no workspace. |
| 2 | Mesmo arquivo: bloqueio sem perguntas e grupo paralelo sem perguntas com o ajuste desligado não criam análise. Bloqueio com perguntas e o ajuste desligado: o questionário tem `"origem" => "agente"`. |
| 3 | Os testes existentes da análise continuam passando (pipeline padrão = ligado). Um teste novo zera a chave (`pipeline_context: Map.delete(ctx, "auto_analysis")` via `Repo.update`) e confere que a análise é pedida. |
| 4 | `tasks_test.exs` (perto da linha 1990, que já afirma o `pipeline_context`): o retrato inclui `"auto_analysis" => true`. Outro teste cria a tarefa com o ajuste ligado, desliga no pipeline (`Pipelines.update_pipeline`), faz a etapa falhar e afirma que a análise foi pedida. |
| 5 | `apps/pipe_maestro/test/pipe_maestro/pipelines_test.exs` (onde estão os testes de `Yaml`): desligado exporta `auto_analysis: false`; ligado não exporta a chave; a ida e volta `to_yaml` → `from_yaml` → `create_pipeline` preserva `false`; um YAML sem a chave importa `true`; `without_caps/1` mantém `"auto_analysis"`. Também o teste do `ImproveKind` (em `test/pipe_maestro/proposals/`) para `with_caps_of` manter o valor atual. |
| 6 | `apps/pipe_maestro_web/test/pipe_maestro_web/live/pipeline_live_test.exs`: abre o drawer na aba Entrega, vê `pipeline-auto-analysis` marcado, envia o form com `auto_analysis: "false"`, confere no banco e ao reabrir, e confere `pipeline-summary-no-analysis` no resumo. |
| 7 | `apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs` (perto da linha 288): tarefa de pipeline desligado, etapa esgotada. Confere o motivo e os botões Refazer, Seguir, Cancelar e "Sugerir com IA" pelos `data-testid` já usados no arquivo, e a ausência dos indicadores de análise (os testids de `analysis_state`). Se fizer sentido, o mesmo em `decisions_live_test.exs`. |
| 8 | e2e acima. |

Durante a implementação rodo os testes de cada arquivo tocado e, no fim, `make ci` uma vez.

## Documentação

- **ADR**: o ajuste completa uma consequência prevista no ADR 0029, sem decisão de arquitetura nova. Basta uma nota no ADR 0029: troco "fica para depois" por "o pipeline a desliga com `auto_analysis` (ligado por padrão; tarefas guardam o valor no retrato)". Não é preciso um ADR novo.
- **`docs/specs/maquina-de-estados-tarefa.md`**:
  - §"Análise automática" (linha ~167): "Na pausa por falha, ou num bloqueio sem perguntas, **com o ajuste `auto_analysis` do pipeline ligado** (padrão; uma tarefa sem a chave no retrato conta como ligado)…" e "Desligado, a pausa leva só o motivo."
  - As linhas da tabela "da análise" (~73, 75) e o item de passos em paralelo (~120) ganham "(se ligada)".
- `docs/plano/` não muda. Nenhum guia muda.

## Riscos

- **Migração**: `ADD COLUMN … DEFAULT true NOT NULL` é instantânea no Postgres 16 e sem risco para os dados.
- **Dados existentes**: as tarefas antigas não têm a chave no retrato, e `!= false` as trata como ligadas, então nada muda para elas.
- **Concorrência**: nenhuma nova. A decisão de pedir a análise lê só o retrato imutável da tarefa, dentro do mesmo `await/3`.
- **Cobertura**: são poucas linhas novas, todas cobertas pelos testes acima.
- **Dialyzer**: atualizar o `@type t` com `auto_analysis: boolean()`. O helper privado devolve `boolean()`.
- **Form**: um switch desmarcado precisa enviar `"false"`. O `<.field type="switch">` do Petal manda um hidden `false`, como já acontece com `auto_merge`. Se não mandar, o `cast` não recebe a chave e o valor fica `true`, e o teste LiveView do critério 6 pega isso.
- **Proposta de melhoria**: sem o ajuste em `ImproveKind`, um agente poderia religar a análise numa melhoria. O plano mantém o valor atual.
