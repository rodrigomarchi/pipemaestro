# 02 — Testes que falham

Base: `origin/main` em `225fdfd`, que já estava integrado, mais o commit do plano. Esta etapa
mexeu só em testes e no dublê de teste `fake_claude`; nenhum código de produção mudou.
`mix format` passa.

## O que os testes fixam: a API combinada com o plano

| Peça | Contrato |
|---|---|
| `TaskKind.schema/0` | `perguntas == Prompt.questions_schema()`, fora de `required` |
| `TaskKind.result/2` | `questions`: as perguntas normalizadas (ou `[]`); `legacy_questions`: as frases antigas (ou `[]`) |
| `TaskKind.changeset/2` | `feedback` com até 8 000 caracteres |
| `Tasks.Questionnaire.question_text/1` | "Pergunta? — Opção (recomendada) · Outra", só a pergunta quando não há opções |
| `Tasks.Questionnaire.to_text/1` | lista numerada (`1. …`), uma pergunta por linha, `""` quando vazia |
| `Proposals.answer_questions/4` | `(user, workspace, job, answers)` devolve `{:ok, nova_proposta}` ou `{:error, String.t()}`; o feedback traz "Respostas às suas perguntas", cada pergunta e a resposta, e o "Outro" cortado; registra o evento de auditoria `proposal.answered` |
| `ProposalLive.Show` | `QuestionnaireLive` com `key="proposta"`, sem `advance` nem `cancel`; o evento `"questionnaire"` com `action=answer` |
| Comentário de triagem | perguntas numeradas, com as opções e a recomendada indicada, também sem auto-approve |

## Testes novos ou alterados, e por que falham

Sessenta a setenta caracteres de cada falha bastam para mostrar o motivo. Os logs completos
ficaram em `tmp/t-domain.log`, `tmp/t-web.log` e `tmp/e2e.log`.

### `apps/pipe_maestro/test/pipe_maestro/tasks/questionnaire_test.exs`

O bloco novo é `describe "question_text/1 and to_text/1"`, com 3 testes:

```
** (UndefinedFunctionError) function PipeMaestro.Tasks.Questionnaire.question_text/1 is undefined or private
** (UndefinedFunctionError) function PipeMaestro.Tasks.Questionnaire.to_text/1 is undefined or private
```

A falha é a esperada: as funções ainda não existem. Hoje a formatação é uma função privada
do `Feedback`.

### `apps/pipe_maestro/test/pipe_maestro/proposals_test.exs`

O bloco novo é `describe "task: structured questions (ADR 0029)"`. Também mudou o teste
existente da linha 253, de `questions` para `legacy_questions`.

| Teste | Falha | Por que é a falha certa |
|---|---|---|
| the schema asks for the questionnaire of the stages | `left: %{"items" => %{"type" => "string"}, ...}` | o schema ainda pede strings |
| the system prompt teaches how to ask | `assert prompt =~ "recomendada"` | o prompt de sistema não ensina o formato |
| valid questions come normalized… | `right: []` em `[timeout, screens] = result.questions` | `result/2` descarta os mapas |
| old phrases are kept apart, and garbage reads as no questions | `["Qual o timeout?", 3, nil]` | as frases ainda saem em `questions`, e `legacy_questions` não existe |
| writes a task from an idea… (existente, linha 253) | `left: ["Qual o timeout aceitável?"]`, `right: []` | as frases ainda saem em `questions` |
| the auto-approval's reason lists each question and its options | `left: "O agente não considerou a tarefa pronta."` | o motivo descarta as perguntas estruturadas |
| answering asks a new round… / a long Other is cut… / incomplete or invalid answers… / only a finished task proposal… | `UndefinedFunctionError … Proposals.answer_questions/4` | a função ainda não existe |
| the feedback of a round takes up to 8 000 characters | `{:error, #Ecto.Changeset<…>}` para 8 000 | o limite ainda é 4 000 |

**Passa já, de propósito:** "the auto-approval's reason still lists old phrases". Ele
garante a compatibilidade com o formato antigo, que hoje já funciona.

### `apps/pipe_maestro/test/pipe_maestro/integrations/ingest_test.exs`

Há 2 testes novos no bloco "the label trigger", com os helpers `finish_triage/3` e
`browser_questions/0`.

| Teste | Falha | Por que |
|---|---|---|
| a triage's structured questions reach the issue numbered… | o corpo diz só "O agente não considerou a tarefa pronta." | o `reason` não lista as perguntas estruturadas |
| a triage without auto approval also tells its questions… | o corpo diz "A IA escreveu a tarefa…" e não lista perguntas | o caso sem auto-approve ainda não mostra as perguntas |

O teste existente "a triage that is not ready asks its questions on the issue", com
frases, continua passando e cobre o formato antigo.

### `apps/pipe_maestro_web/test/pipe_maestro_web/live/proposal_live_test.exs`

O bloco novo é `describe "task: the agent's questionnaire"`, com 4 testes. O teste
existente "opens the new-task form…" ganhou um `refute` de `questionnaire-proposta` para
as frases.

| Teste | Falha | Por que |
|---|---|---|
| the questions are a questionnaire to answer, not a list | `assert has_element?(view, "[data-testid=questionnaire-proposta]")` | a tela ainda não tem o questionário |
| answering asks the agent to rewrite the task… | `expected selector "[data-testid=questionnaire-form-proposta]" … got none` | idem |
| answers that do not answer every question are refused | `FunctionClauseError … ProposalLive.Show.handle_event/3` com `"questionnaire"` | o evento não é tratado |
| a proposal turned into a task shows its questions without sending | `assert has_element?(view, "[data-testid=questionnaire-proposta]")` | a leitura do questionário ainda não aparece |

Os outros 26 testes do arquivo passam.

### e2e: `e2e/tests/agent-proposals.spec.ts` e `e2e/pages/ProposalPage.ts`

- O cabeçalho ganhou `@flow F` (ainda sem `[done]`): responder ao questionário de uma
  tarefa não pronta pede uma nova rodada com as respostas, e essa rodada vira a tarefa.
- No Flow E, o motivo passa a ter de mostrar `100 simultâneos (recomendada)`.
- O Flow F faz o caminho completo:
  1. confere o questionário, a opção recomendada primeiro e a ausência de `advance`;
  2. tira a captura `task-proposal-questions`;
  3. escolhe uma opção, revisa e confirma;
  4. confere que a URL muda para a nova proposta;
  5. a nova rodada, com auto-approve, vira a tarefa, cuja entrada traz "100 logins
     simultâneos";
  6. tira a captura `task-proposal-answered`.
- O `ProposalPage` ganhou `questionnaire`, `questionnairePart`, `questionOption` e
  `sendAnswers`, todos por `getByTestId` com o sufixo `-proposta`.
- `make e2e.typecheck` passa (código 0).
- `make e2e FILE=tests/agent-proposals.spec.ts` sai com código 2 e falha no ponto certo:

```
> 120 |     await expect(proposal.autoApproveSkipped).toContainText("Qual o limite de logins simultâneos?");
Error: expect(locator).toContainText(expected) failed
```

O dublê já devolve a pergunta estruturada, mas o motivo do auto-approve ainda a descarta.

### Dublê: `apps/pipe_maestro_runner/test/support/fake_claude`

- `[nao-pronta]` responde uma pergunta estruturada, "Qual o limite de logins
  simultâneos?", com "100 simultâneos" como recomendada e com preview, e "1 000
  simultâneos" como segunda opção.
- Um prompt com "Respostas às suas perguntas" responde uma tarefa pronta ("Melhorar o login
  para 100 acessos"). Essa condição é verificada antes de `[nao-pronta]`, porque o pedido
  continua no prompt da nova rodada.
- Os dois JSONs foram validados, e `bash -n` passa.

## Testes vizinhos

- `cd apps/pipe_maestro && mix test` nos três arquivos tocados: 91 de 107 passam, e as 16
  falhas são exatamente as listadas acima.
- `proposal_live_test.exs`: 26 de 30 passam, e as 4 falhas são as novas.
- A suíte do runner (`cd apps/pipe_maestro_runner && mix test`): 283 de 284 passam. A falha
  foi em `gates_test.exs:54`, "a change to the tree runs it again, committed or not". Ela
  não tem relação com o `fake_claude`: é o cache de gates por árvore. Passou em 5 de 5
  execuções isoladas, então é intermitente sob carga, em
  `PipeMaestroRunner.GateCache.tree/3`. **Fica para a etapa de implementação**, que deve
  investigar e corrigir, pela regra "todo erro encontrado é seu".
- Não mexi em `task_live_test.exs`, `decisions_live_test.exs` nem
  `decision-questionnaire.spec.ts`. Eles provam, depois da implementação, que as decisões
  de tarefa não mudaram.
