# 02 — Testes que falham: pipeline escolhido e auto-aprovação da tarefa escrita com IA

Os testes descrevem o comportamento do plano (`01-plano.md`) sem implementá-lo. Nenhum código de
produção foi tocado.

## Arquivos

| Arquivo | O que descreve |
|---|---|
| `apps/pipe_maestro/test/pipe_maestro/proposals_test.exs` | `describe "task: the chosen pipeline"` e `describe "task: auto-approval"` |
| `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs` | `describe "create_task/4 from a proposal"` |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/proposal_live_test.exs` | dois testes novos em `"asking"` e `describe "task auto-approval"` |
| `e2e/tests/agent-proposals.spec.ts` | fluxo A com o toggle desligado; novos fluxos D (auto-criada, pipeline escolhido) e E (pulada, não pronta) |
| `e2e/pages/ProposalPage.ts` | `submitRequest` aceita `pipeline` e `autoApprove`; `createdTaskLink`, `autoApproveSkipped` |
| `apps/pipe_maestro_runner/test/support/fake_claude` | marcador `[nao-pronta]`: a proposta de tarefa responde `pronta: false` com uma pergunta (para o fluxo E) |

## Contrato que os testes fixam (para a implementação)

Domínio:
- `TaskKind`: campos `pipeline_id` (validado no workspace: "não é um pipeline deste workspace") e
  `auto_approve` (ausente → não guardado; `"false"` → `false` guardado).
- Com `pipeline_id`, o prompt cita só o pipeline escolhido (`**Funcionalidade**`, e não os
  outros), e `result/2` usa esse pipeline em `pipeline`, `pipeline_name` e
  `task_params["pipeline_id"]`. Se ele foi apagado depois, cai para a sugestão do agente.
- `Proposals.job_finished/1 :: :ok`, `Proposals.created_task_id/1`, `Proposals.auto_approve/1`
  (`nil`, `%{"status" => "created"}` ou `%{"status" => "skipped", "reason" => texto}`) e
  `Proposals.create_task/4 (user, workspace, job, params)`.
- `Jobs.finish_job/3` de uma proposta `task` com auto-aprovação cria a tarefa (`running`, ou
  `queued` além de `max_running_tasks`), em nome de quem pediu, e registra `"task.auto_created"`
  no `Audit` com `details["proposal_id"]`.
- O motivo de pular contém "pronta" e as perguntas; o nome sugerido quando nenhum pipeline
  resolve; o erro do changeset ("o runner não oferece esse diretório") quando a criação falha.
- `Tasks.create_task/4` com `proposal: job` grava `tasks.proposal_job_id`. A segunda vez dá
  `"esta proposta já virou uma tarefa"` em `proposal_job_id`. O formulário não forja o vínculo
  (fora do `cast`).

Web:
- Modal de tarefa: `select[data-testid=proposal-request-pipeline]` com a opção vazia "Deixar o
  agente escolher" e nenhuma `option[selected]`. `input[data-testid=proposal-request-auto-approve]`
  marcado por padrão: o `data-testid` vai no `<input>`, que é onde o `<.field type="switch">` do
  Petal põe o `@rest`.
- `ProposalLive.Show`: `proposal-created-task-link` (href para a tarefa) no lugar de
  `proposal-create-task`; `proposal-auto-approve-skipped` com o motivo; com a página aberta,
  `assert_redirect` para a tarefa quando ela nasce.
- `/tasks?proposta=<id>` de proposta que já virou tarefa → `live_redirect` para ela. O formulário
  manual liga a tarefa à proposta.
- e2e: novo `data-testid="task-pipeline-name"` no `<p>` com `{@task.pipeline_name} · v…` de
  `TaskLive.Show` (hoje sem test id).

## Resultado: falham pelo motivo certo

`mix test apps/pipe_maestro/test apps/pipe_maestro_web/test`: as **21 falhas são todas testes
novos**. Os testes que já existiam passam. `mix test apps/pipe_maestro_runner/test`: 167/167 com o
`fake_claude` alterado.

### Domínio (14)

```
create_task/4 from a proposal links the task to the proposal's job, once
  ** (UndefinedFunctionError) function PipeMaestro.Tasks.create_task/4 is undefined or private.
create_task/4 from a proposal the form cannot forge the link
  ** (KeyError) key :proposal_job_id not found in: %PipeMaestro.Tasks.Task{...}
task: the chosen pipeline a pipeline of another workspace is refused; ...
  ** (KeyError) key :pipeline_id not found in: %{}         # errors_on: o campo ainda não existe
task: the chosen pipeline the agent writes for the chosen pipeline, whatever it names back
  Assertion with == failed  left: nil  right: <chosen.id>   # input não guarda pipeline_id
task: auto-approval a ready task is created and started on behalf of who asked
  Assertion with == failed  left: nil  right: true          # input não guarda auto_approve
task: auto-approval (não pronta | sem pipeline | erro de criação | desligada | job falho | limite)
  ** (Ecto.QueryError) field `proposal_job_id` in `where` does not exist in schema PipeMaestro.Tasks.Task
task: auto-approval finishing twice or creating by hand afterwards makes a single task
  ** (Ecto.QueryError) field `proposal_job_id` ... does not exist
task: auto-approval creating by hand links the task to the proposal
  ** (UndefinedFunctionError) function PipeMaestro.Proposals.create_task/4 is undefined or private
task: auto-approval other kinds of proposal are left alone
  ** (UndefinedFunctionError) function PipeMaestro.Proposals.job_finished/1 is undefined or private
```

Todas faltam pela ausência da coluna `proposal_job_id`, das funções novas ou dos campos novos do
`TaskKind`, que são o que a implementação vai criar. O teste "a chosen pipeline deleted since falls
back to the agent's suggestion" **passa** hoje e serve de guarda de regressão: o comportamento
atual já é cair para a sugestão.

### Web (7)

```
asking tasks: a pipeline to write for, and auto-approval on by default
  Expected truthy, got false
  code: assert has_element?(view, "select[data-testid=proposal-request-pipeline] option[value='']", ...)
asking tasks: auto-approval can be turned off
  ** (ArgumentError) could not find non-disabled input, select or textarea with name "proposal[auto_approve]"
task auto-approval a task created from the proposal is linked in place of the create button
task auto-approval with the page open, the task created on its own takes the person to it
task auto-approval the new-task form of a proposal already turned into a task goes to it
  ** (MatchError) no match of right hand side value: []
  code: [task] = Tasks.list_tasks(ctx.workspace)            # nada cria a tarefa no fim do job
task auto-approval a proposal that could not be created on its own says why
  Expected truthy, got false
  code: assert has_element?(view, "[data-testid=proposal-auto-approve-skipped]", "Qual o timeout?")
task auto-approval the form links the task it creates to the proposal
  ** (KeyError) key :proposal_job_id not found in: %PipeMaestro.Tasks.Task{...}
```

Cada falha aponta o que falta: os campos do modal, a criação automática, o aviso de pulo e o
vínculo `proposal_job_id`. O teste existente "opens the new-task form filled with the task the
agent wrote" continua passando, porque um pedido sem `auto_approve` segue desligado.

### Playwright

`make e2e.typecheck`: **passa** (exit 0). A suíte e2e não foi rodada (não é exigida nesta
etapa). Em execução, o spec falharia já no fluxo A, em
`expect(getByTestId("proposal-request-auto-approve")).toBeChecked()`, porque o elemento ainda não
existe. Os fluxos D e E dependem de `proposal-request-pipeline`, `proposal-created-task-link`,
`task-pipeline-name` e `proposal-auto-approve-skipped`. O fluxo D aceita tanto a navegação ao vivo
quanto o link, se a tarefa nascer antes de a página conectar. A contagem final em `/proposals` passa
de 4 para 6 (três tarefas). Shots novos: `task-proposal-auto-created` e
`task-proposal-auto-skipped`. `task-proposal-request` agora mostra os campos novos.
