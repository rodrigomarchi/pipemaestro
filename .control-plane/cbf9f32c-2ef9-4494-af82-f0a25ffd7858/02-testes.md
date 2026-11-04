# Testes que falham: a plataforma impõe tetos de custo que ninguém pediu

Os testes descrevem o comportamento do plano (`01-plano.md`) sem implementá-lo.
Não entrou nenhum stub. Toda falha é de asserção sobre o comportamento atual.

## O que entrou

### `apps/pipe_maestro/test/pipe_maestro/proposals_test.exs`
Helpers novos:
- `refute_budget/1`: o contexto do job não tem a chave `"max_budget_usd"`, e o
  `PipeMaestroProtocol.Job` resultante tem `max_budget_usd: nil`.
- `refute_caps/1`: o texto não contém `orçamento`, `teto` (palavra), `max_task_cost_usd` nem `max_budget_usd`.
- `@capped_output`: a resposta de pipeline com `max_task_cost_usd: 40` e `max_budget_usd: 2` na
  primeira etapa.

| Teste | Critério |
|---|---|
| `pipeline` › "neither the instructions nor the answer carry a cost cap" | 1, 2 (instruções e resposta descartada) |
| `task` › "runs without a cost cap" | 1 |
| `decision` › "runs without a cost cap" | 1 |
| `improve` › "keeps the pipeline's own caps, which the agent never sees" | 1, 2 (YAML do prompt sem teto), 3 |
| `improve` › "a pipeline without caps is improved without caps" | 3 |
| `the schemas` › "a pipeline in an answer has no cost cap" | 2 (schemas de `PipelineKind` e `ImproveKind`) |
| `the schemas` › "how a pipeline works says nothing of a cost cap" | 2 (`Instructions.pipeline_format/0`, com o exemplo) |

No teste de melhoria, o pipeline tem `max_task_cost_usd: "40"`, `plano` com `"1.5"` e `codigo`
com `"3"`. O agente devolve `5`, `plano` sem teto, tira `codigo` e cria `revisao` com `9`. O
resultado esperado é `"40"`, `"1.5"` em `plano` e nada em `revisao`, e salva assim.

### `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs`
- "without a cap the task goes on, with no alert and no budget for its stages" (critério 4):
  é o teste "without a cap the task goes on", ampliado. Os jobs das duas etapas vão com
  `max_budget_usd` nil, e `Tasks.alerts/2` fica vazio depois de US$ 99.
  **Passa hoje.** É um teste de regressão: o plano não muda `Tasks`. Os testes do critério 5
  (linhas 737 e 815) continuam passando.

### `apps/pipe_maestro_runner/test/pipe_maestro_runner/job_runner_test.exs`
- "argv has no budget when the job carries none" (critério 6). **Passa hoje.** O runner não
  muda, e o teste fixa esse comportamento.
- `test/support/fake_claude`: a resposta de proposta de pipeline agora traz
  `max_task_cost_usd: 40` e `max_budget_usd: 2` na etapa `plano`, como um agente que propõe
  teto. O e2e usa isso, e nenhum teste do runner depende desses campos (a suíte do runner
  passa inteira).

### `apps/pipe_maestro_web/test/pipe_maestro_web/live/pipeline_live_test.exs`
- "the list shows each pipeline's delivery, budget and stages": `"Sem teto"` passa a
  `"Sem limite de custo"`.
- "the form says an empty cost cap is no limit" (critério 7): os rótulos, as ajudas e a
  descrição da seção "Execução" do plano. Também confere que "Orçamento" não aparece.

### `apps/pipe_maestro_web/test/pipe_maestro_web/live/proposal_live_test.exs`
- `pipeline` › "a cost cap the agent proposes does not reach the form": o formulário aberto
  com `?proposta=` mostra `pipeline-max-cost` e `stage-budget-0` vazios, e salva sem teto.
- `improve` › "the revision keeps the pipeline's own cost caps": `pipeline-max-cost` mostra
  `40` (o agente devolveu `5`), `stage-budget-0` mostra `1.5`, e a etapa nova vai vazia.

### e2e
- `e2e/pages/PipelinesPage.ts`: `maxCost` e `stageBudget(index)` (só `getByTestId`, ids que já
  existem).
- `e2e/tests/pipeline-proposal.spec.ts`: novo `@flow C [todo]`. O formulário aberto pela
  proposta tem `pipeline-max-cost` e `stage-budget-0` vazios. A implementação passa o fluxo
  para `[done]`.

## Execução

`mix format` rodado. `mix test` (raiz) completo:

```
==> pipe_maestro_protocol   Result: 76 passed
==> pipe_maestro            Result: 189/196 passed (1/1 doctest, 188/195 tests)
==> pipe_maestro_web        Result: 248/252 passed
==> pipe_maestro_runner     Result: 162 passed
```

As 11 falhas são exatamente os testes novos ou alterados. Os testes que já existiam
continuam passando.

### Por que cada falha é a esperada

**Critério 1: as propostas ainda levam teto.** Os testes de tarefa, decisão, pipeline e
melhoria falham no `refute_budget/1`:
```
  4) test decision runs without a cost cap (PipeMaestro.ProposalsTest)
     code: refute Map.has_key?(job.context, "max_budget_usd")
         %{"directory" => "app", "max_budget_usd" => 2, ...
  6) test task runs without a cost cap            ... "max_budget_usd" => 2
  7) test pipeline neither the instructions ...   ... "max_budget_usd" => 3
  3) test improve keeps the pipeline's own caps   ... "max_budget_usd" => 3
```
O `job/3` de cada `Kind` ainda fixa US$ 2 ou US$ 3, e `Proposals.request/5` põe esse valor
no contexto. No teste de pipeline e no de melhoria, as asserções de instruções, resposta e
preservação do teto vêm depois. Elas também falham com o código atual: o `pipeline_format`
fala em "orçamento", o `to_yaml/1` mostra `max_task_cost_usd: "40"`, e o resultado traz o
`5` do agente. Esses pontos aparecem isolados nas falhas a seguir.

**Critério 2: schema e instruções.**
```
  5) test the schemas a pipeline in an answer has no cost cap
     code: refute Map.has_key?(schema["properties"], "max_task_cost_usd")
  2) test the schemas how a pipeline works says nothing of a cost cap
     code:  assert Regex.scan(~r/orçamento|\bteto|max_task_cost_usd|max_budget_usd/iu, text) == []
     left:  [["orçamento"]]
```
`pipeline_schema/0` ainda declara `max_task_cost_usd`, e `pipeline_format/0` diz "só uma
regra, uma falha ou o orçamento param a tarefa".

**Critério 2 (resposta) e 3: o resultado ainda passa o teto do agente.**
```
  1) test improve a pipeline without caps is improved without caps
     code: refute Map.has_key?(result.pipeline, "max_task_cost_usd")
         %{"max_task_cost_usd" => 40, "stages" => [%{"key" => "plano", "max_budget_usd" => 2, ...
```
`Yaml.from_map/1` aceita os dois campos, e `ImproveKind.result/2` não os descarta nem
recoloca os tetos do pipeline.

**Critério 7: os textos do formulário e da lista.**
```
  1) test the prompt editor the list shows each pipeline's delivery, budget and stages
     code:  assert meta =~ "Sem limite de custo"
     left:  "...<dd>Sem teto</dd>..."
  2) test the prompt editor the form says an empty cost cap is no limit
     code:  assert html =~ "Teto de custo por tarefa (US$, opcional)"
```
Hoje, o rótulo é "Orçamento por tarefa (US$, opcional)", e a lista mostra "Sem teto".

**Formulário aberto pela proposta (critérios 2 e 3, ponta a ponta na LiveView).**
```
  4) test pipeline a cost cap the agent proposes does not reach the form
     code:  refute form |> element("[data-testid=pipeline-max-cost]") |> render() =~ ~s(value="40")
     left:  "<input ... name=\"pipeline[max_task_cost_usd]\" ... value=\"40\" ... data-testid=\"pipeline-max-cost\"/>"
  3) test improve the revision keeps the pipeline's own cost caps
     code:  assert form |> element("[data-testid=pipeline-max-cost]") |> render() =~ ~s(value="40")
     left:  "<input ... value=\"5\" ... data-testid=\"pipeline-max-cost\"/>"
```
O teto do agente (`40`, `5`) ainda chega ao formulário. Na melhoria, ele substitui o teto do
pipeline (`40`).

### e2e
- `make e2e.typecheck`: passa (exit 0).
- `make e2e FILE=tests/pipeline-proposal.spec.ts`: falha no ponto do fluxo C, pelo motivo
  esperado:
```
  ✘  1 [chromium] › tests/pipeline-proposal.spec.ts:28:7 › Pipeline proposal › the agent studies a directory and proposes a pipeline and its project
    Error: expect(locator).toHaveValue(expected) failed
    Expected: ""
    Received: "40"
        at e2e/tests/pipeline-proposal.spec.ts:86:37
```
Os fluxos A e B, antes desse ponto, passam. O `40` é o `max_task_cost_usd` que o
`fake_claude` agora propõe e que hoje chega ao formulário.

## Observações para a implementação
- A falha de critério 1 no teste de melhoria vem antes das outras asserções. Ao implementar,
  confira que as asserções de prompt (`refute_caps(job.prompt)`, o YAML sem teto) e de
  resultado (`"40"`, `"1.5"`) também passam.
- Os testes da LiveView esperam o teto da melhoria em texto (`value="40"`, `value="1.5"`),
  como o plano pede ("em texto como o formulário espera").
