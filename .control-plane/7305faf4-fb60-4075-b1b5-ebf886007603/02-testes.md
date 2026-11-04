# Testes que falham: Tela melhor de decisão

Os testes descrevem o comportamento do plano (`01-plano.md`). Nenhum código de produção foi
tocado. `mix format` rodou.

## Arquivos

| Arquivo | O que cobre | Critérios |
|---|---|---|
| `apps/pipe_maestro/test/pipe_maestro/tasks/questionnaire_test.exs` (novo) | `normalize/1`: limites, truncagens, ordenação e `preview`. Também `from_options/1`, `for_run/1`, `validate_answers/2` e `to_markdown/2` | A1, A2 |
| `apps/pipe_maestro/test/pipe_maestro/pipelines/prompt_test.exs` (novo) | `perguntas` no schema base, `Prompt.questions_schema/0`, `opcoes` "obsoleto", sem `if/then`. O cabeçalho cita `perguntas` e `AskUserQuestion`. A seção de respostas vem depois do feedback e só aparece quando há respostas | A5 |
| `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs` | describe novo "the decision questionnaire" e um teste de grupo em "stages in parallel" | A2–A6 |
| `apps/pipe_maestro/test/pipe_maestro/proposals_test.exs` | describe novo "analysis" (`AnalysisKind`) | A3 |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs` | describe novo "the decision questionnaire" | A4, A7–A10 |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/decisions_live_test.exs` | o questionário por tarefa, respondido da lista | A8 |
| `apps/pipe_maestro_web/test/pipe_maestro_web/components/questionnaire_components_test.exs` (novo) | `QuestionnaireComponents.questionnaire/1` em modo leitura | A7 |
| `e2e/tests/decision-questionnaire.spec.ts` (novo) | fluxos A (bloqueio com perguntas), B (falha com análise) e C (página Decisões), marcados `[todo]` | A11 |
| `e2e/pages/TasksPage.ts` | `questionnaire`, `questionnairePart`, `question`, `questionOption`, `answerQuestion`, `fillOther`, `submitAnswers`, `confirmAnswers` e `openManualDecision`. `retryWith` agora abre o bloco "Decidir sem responder" quando ele está recolhido | A11 |

### Ajuste em teste existente

`tasks_test.exs`, "a decision is commented on the issue with the next stage": o teste passa a
ler o job da nova tentativa com `current_job/1` em vez do próximo `{:job_assign, _}`. Com a
análise automática, o bloqueio sem perguntas também despacha o job de análise, e o primeiro
`job_assign` deixaria de ser o da etapa. O teste continua passando hoje.

## Contrato que os testes fixam (para a implementação)

Os testes assumem estas decisões, que o plano deixava em aberto:

- **`Questionnaire.normalize/1`** recebe o valor cru de `perguntas`, não a saída inteira, e
  devolve `{:ok, perguntas} | :error`. `preview` ausente vira `nil`.
- **`Questionnaire.for_run/1`** devolve o questionário completo
  (`%{"origem" => "agente" | "opcoes", "perguntas" => …}`) ou `nil`.
  **`from_options/1`** devolve a lista com uma pergunta.
- **`validate_answers/2`** devolve `{:ok, respostas}`, com as respostas recebidas, ou
  `{:error, motivo}`.
- **`Prompt.build/2`** recebe `context.answers` como
  `%{"perguntas" => …, "respostas" => …}`, o mesmo mapa gravado em `StageRun.answers`.
- **`Decision`.** `questions` é `%{"perguntas" => …}` e `answers` é `%{"respostas" => …}`.
- **`Tasks.answer(task, respostas, instructions, opts)`** devolve `{:ok, task}`,
  `{:error, :invalid_answers, motivo}` ou `{:error, :not_awaiting}`.
  **`Tasks.advance/3`** aceita `answers:` em `opts`.
- **`Tasks.questionnaire/1`** devolve `%{questionnaire: map | nil, analysis: :none | :running | :failed}`:
  - `:failed` quando o job de análise terminou sem questionário (falhou, foi cancelado ou deu
    saída inválida);
  - `:none` quando o questionário veio do agente.
- **`AnalysisKind`.**
  - `result/2` devolve `%{task_id, diagnosis, questions}`.
  - O job tem `max_budget_usd` 1 e `timeout_ms` de 10 min.
  - `schema()["properties"]["perguntas"] == Prompt.questions_schema()`.
- **Ao decidir**, a análise que está rodando recebe `cancel_requested_at`, e
  `decision_analysis_job_id` volta a `nil`.
- **LiveComponent.** Os testes interagem pelo formulário
  `[data-testid=questionnaire-form]` (o id ganha o sufixo `-<task_id>` na página Decisões),
  que tem `phx-change` e `phx-submit`.
  - Os parâmetros chegam como
    `%{"answers" => %{"0" => %{"escolhas" => [rótulos], "outro" => "texto"}}}`.
  - Perguntas e opções são indexadas a partir de 0, como os `decision-option-<n>` de hoje.
  - O submit abre a revisão (`questionnaire-review`), e `questionnaire-confirm` envia.
  - O progresso mostra "N de M".
  - Depois de responder, a outra sessão mostra o flash "Outra pessoa respondeu".
- **`data-testid` novo além da tabela do plano:**
  - `questionnaire-form`, já descrito acima;
  - `decision-manual-toggle`, o botão ou `summary` que abre "Decidir sem responder". O e2e
    usa só `getByTestId`, então não dá para clicar no `<details>` por estrutura.
- **`fake_claude`.** O e2e depende dos marcadores do plano, que ainda não existem:
  - `[perguntas]`, que gera uma pergunta simples (com a opção recomendada primeiro) e uma
    múltipla;
  - o tipo `analysis`, cuja recomendada é "Tentar sem falha";
  - `[falha]`, que passa a ser ignorado quando o prompt contém "Tentar sem falha".

## Resultado: falham pelo motivo certo

`mix test` na raiz, com saída em `/tmp/all.log`, terminou com exit code 2:

```
Result: 76 passed                              # pipe_maestro_protocol
Result: 190/234 passed (1/1 doctest, 189/233 tests)
Failed: 44 tests                               # pipe_maestro
Result: 249/259 passed
Failed: 10 tests                               # pipe_maestro_web
Result: 161 passed                             # pipe_maestro_runner
```

**As 54 falhas são exatamente os testes novos.** Todos os testes que já existiam passam,
inclusive o que foi ajustado. Os motivos, por grupo:

### `QuestionnaireTest` (19): o módulo não existe

```
** (UndefinedFunctionError) function PipeMaestro.Tasks.Questionnaire.validate_answers/2 is undefined (module PipeMaestro.Tasks.Questionnaire is not available)
```

É a falha esperada: `PipeMaestro.Tasks.Questionnaire` ainda não foi escrito.

### `PromptTest` (5 de 6): o schema e o cabeçalho ainda são os antigos

```
code:  assert perguntas["type"] == "array"
left:  nil
---
code:  assert schema["properties"]["opcoes"]["description"] =~ "obsoleto"
left:  "quando bloqueado, os caminhos possíveis para a pessoa escolher, em frases curtas"
---
code:  assert prompt =~ "AskUserQuestion"
left:  "Você está executando a etapa \"Etapa A\" (1) … Faça A: O botão não responde"
---
code:  assert prompt =~ "Respostas da pessoa às suas perguntas"
left:  "… A tentativa anterior desta etapa não passou. Corrija o que levou a isso:\nA tentativa anterior falhou."
```

São falhas de asserção sobre o comportamento atual. O sexto teste passa ("without answers
there is no answers section"): ele protege o caso sem respostas.

### `TasksTest` (15): os campos e funções novos não existem

```
** (KeyError) key :decision_questionnaire not found in: %PipeMaestro.Tasks.Task{…}
** (KeyError) key :decision_analysis_job_id not found in: %PipeMaestro.Tasks.Task{…}
** (KeyError) key :answers not found in: %PipeMaestro.Tasks.Decision{…}
** (UndefinedFunctionError) function PipeMaestro.Tasks.answer/4 is undefined or private
```

Faltam as colunas e campos (`decision_questionnaire`, `decision_analysis_job_id`,
`Decision.answers`) e a função `answer/4`. "a decision twice on the same pause" passa na
segunda `retry_stage` e para em `answer/4`.

### `ProposalsTest` (5): não há análise automática nem tipo `analysis`

```
code:  assert "analysis" in Proposals.kinds()
---
** (MatchError) no match of right hand side value: nil
code: job = analysis!(ctx)        # "expected the failure to ask for an analysis"
```

A falha da etapa não pede análise, e o tipo `analysis` não está em `Proposals.kinds/0`.

### `TaskLiveTest` (6): a tela não tem o questionário

```
Expected truthy, got false
code: assert has_element?(view, "[data-testid=questionnaire]")
---
** (ArgumentError) expected selector "[data-testid=questionnaire-form]" to return a single element, but got none
---
Expected truthy, got false
code: assert has_element?(view, "[data-testid=questionnaire-analyzing]")
---
expected the failure to ask for an analysis
code: finish_analysis(ctx, analysis_job(ctx, task), …)
```

O painel atual não tem o componente, e a falha não dispara a análise.

### `DecisionsLiveTest` (1)

```
Expected truthy, got false
code: assert has_element?(view, "[data-testid=questionnaire-#{asked.id}]")
```

### `QuestionnaireComponentsTest` (3)

```
** (UndefinedFunctionError) function PipeMaestroWeb.QuestionnaireComponents.questionnaire/1 is undefined (module PipeMaestroWeb.QuestionnaireComponents is not available)
```

### e2e

- **`make e2e.typecheck`** termina com exit code 0: o spec e o page object compilam.
- **O spec não foi rodado.** Ele precisa de um runner real e falharia no primeiro
  `getByTestId("questionnaire")`: o `fake_claude` ainda não conhece `[perguntas]`, então a
  tarefa bloquearia sem perguntas, e a tela não tem o componente.
- **Fluxos do cabeçalho.** Ficam `[todo]` até a implementação.

## Avisos de compilação esperados

Os testes geram avisos de "undefined function" ou "module not available" para
`Questionnaire`, `QuestionnaireComponents`, `AnalysisKind` e `Tasks.answer/4`. Eles somem
quando a implementação existir. O `make ci` (`--warnings-as-errors`) só fica verde depois dela.
