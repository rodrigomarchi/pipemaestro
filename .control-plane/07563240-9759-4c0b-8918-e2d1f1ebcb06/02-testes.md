# Testes que falham: ajuste `auto_analysis` por pipeline

Escrevi os testes antes do código, seguindo o plano (`01-plano.md`). Nenhum código de produção mudou. Todos os testes novos compilam e falham por asserção ou por `KeyError` do campo que ainda não existe; nenhum falha por erro de sintaxe ou de setup. Os testes vizinhos de cada arquivo tocado continuam passando.

## Arquivos

| Arquivo | O que foi acrescentado |
|---|---|
| `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs` | O `describe "a pipeline with the automatic analysis off"`, com 9 testes. O pipeline tem `auto_analysis: "false"`, gate `{{projeto.teste}}` e `max_attempts: 1`. O helper `analysis_jobs/1` lista os `Job` de proposta `analysis` com `task_id` da tarefa. |
| `apps/pipe_maestro/test/pipe_maestro/pipelines_test.exs` | Um teste para o padrão ligado e a ida e volta do YAML: `auto_analysis: false` só quando desligado, import sem a chave fica ligado, `without_caps/1` mantém a chave e `from_map/1` a aceita. |
| `apps/pipe_maestro/test/pipe_maestro/proposals_test.exs` | `improve`: a revisão do agente mantém o `auto_analysis` atual do pipeline, mesmo que proponha `true`. |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/pipeline_live_test.exs` | Drawer: o switch `pipeline-auto-analysis` aparece marcado na aba Entrega com o rótulo "Analisar falhas com IA"; o form salva `false`, o editor reabre desmarcado e a página do pipeline mostra `pipeline-summary-no-analysis`. |
| `apps/pipe_maestro_web/test/pipe_maestro_web/components/pipeline_components_test.exs` | `pipeline_summary/1` mostra `pipeline-summary-no-analysis` só com a análise desligada. Uso `struct/2` para o teste compilar antes do campo existir. |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs` | Tela da tarefa pausada com o ajuste desligado: motivo, `decision-manual`, `decision-retry`, `decision-advance`, `decision-suggest` e `task-cancel` visíveis; nenhum `questionnaire-analyzing`, `questionnaire-analysis-failed` ou `questionnaire`. |
| `e2e/pages/PipelinesPage.ts` | O getter `autoAnalysis` (`pipeline-auto-analysis`). |
| `e2e/tests/pipeline-auto-analysis.spec.ts` | O spec novo: liga e desliga o switch no drawer, tira o `shot` da aba Entrega, salva, confere o resumo e reabre conferindo o switch desligado. |

## Execuções e por que cada falha é a esperada

### `mix test apps/pipe_maestro/test/pipe_maestro/tasks_test.exs`: 97/103, 6 falhas

```
2) ... a gate that fails every attempt pauses with the reason and no analysis
   code:  assert task.decision_analysis_job_id == nil
   left:  "514d62bb-526b-4647-b137-03fd8ad73edb"
3) ... a group with nothing to ask pauses with no analysis
   code:  assert task.decision_analysis_job_id == nil
   left:  "262bf044-..."
4) ... a CLI error that exhausts the attempts pauses with no analysis
   code:  assert task.decision_analysis_job_id == nil
   left:  "f36b101f-..."
6) ... a block with nothing to ask pauses with no analysis
   code:  assert task.decision_analysis_job_id == nil
   left:  "e8a84fef-..."
5) ... the task keeps the setting from the pipeline
   code:  assert %{"auto_analysis" => false} = create_task(ctx).pipeline_context
   right: %{"agents" => nil, "auto_merge" => false, "delivery" => "none", ...}   # sem a chave
1) ... turning it on in the pipeline later does not change a task already created
   code:  assert %Task{status: :awaiting_decision, decision_analysis_job_id: nil} = task
   (a análise foi pedida)
```

- **2, 3, 4 e 6:** o `cast` ainda ignora `auto_analysis`, e `await/3` pede a análise em toda falha e em todo bloqueio sem perguntas. É exatamente o comportamento a condicionar.
- **5:** `Pipeline.context/1` ainda não grava a chave.
- **1:** o retrato da tarefa ainda não guarda o ajuste desligado.

Três testes novos já passam, de propósito, porque fixam o que não deve mudar:

- um bloqueio com perguntas mostra o questionário do agente;
- uma tarefa cujo `pipeline_context` não tem a chave continua com a análise;
- desligar o ajuste no pipeline depois de criar a tarefa não muda essa tarefa.

### `mix test …/pipelines_test.exs …/proposals_test.exs`: 72/74, 2 falhas

```
1) test pipelines the automatic analysis is on by default, and YAML writes it only when off
   ** (KeyError) key :auto_analysis not found in: %PipeMaestro.Pipelines.Pipeline{...}
2) test improve keeps the pipeline's automatic analysis setting, a person's choice
   code:  assert result.pipeline["auto_analysis"] == false
   left:  nil
```

- **1:** o schema ainda não tem o campo. A compilação do teste emite um aviso de tipo pelo mesmo motivo (`on.auto_analysis` num `%Pipeline{}`), e o aviso some quando o campo existir.
- **2:** `from_map/1` e `ImproveKind.with_caps_of/2` ainda não tratam a chave.

### `mix test` (web: `pipeline_live_test`, `task_live_test`, `pipeline_components_test`): 100/103, 3 falhas

```
1) pipeline_summary/1 says when the automatic analysis of failures is off, and only then
   code:  assert text(html, "[data-testid=pipeline-summary-no-analysis]") =~ "análise"
   left:  ""
2) the delivery tab turns the automatic analysis of failures off and keeps it
   Expected truthy, got false
   code: assert has_element?(view, "[data-testid=pipeline-panel-panel-entrega] [data-testid=pipeline-auto-analysis][checked]")
3) with the pipeline's analysis off, a failure shows the reason and the manual decision only
   Expected false or nil, got true
   code: refute has_element?(view, "[data-testid=questionnaire-analyzing]")
```

- **1:** o resumo ainda não tem o aviso.
- **2:** o drawer ainda não tem o switch.
- **3:** com o campo ignorado, a pausa ainda dispara a análise e a tela mostra "analisando…".

### e2e

`make e2e.typecheck`: passou, código de saída 0.

`make e2e FILE=tests/pipeline-auto-analysis.spec.ts`: falhou, código de saída 2.

```
Error: expect(locator).toBeChecked() failed
Locator: getByTestId('pipeline-auto-analysis')
Error: element(s) not found
> 33 |     await expect(pipelines.autoAnalysis).toBeChecked();
```

A falha é a esperada: o switch ainda não existe no drawer, e o login, o backoffice e a abertura da aba Entrega funcionaram até ali.

## Para a etapa de implementação

- A captura `pipeline-auto-analysis` (claro e escuro) sai deste spec com `make e2e.shots FILE=tests/pipeline-auto-analysis.spec.ts`.
- O teste do drawer espera o atributo `checked` no input do switch, como o Petal renderiza para o `pipeline-auto-merge`.
- `mix format --check-formatted` passou.
