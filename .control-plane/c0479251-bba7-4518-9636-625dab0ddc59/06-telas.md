# Etapa 6 — Telas (e2e)

## Houve mudança de tela?

Houve mudança em `apps/pipe_maestro_web/lib`, mas **nenhuma mudança visual**
(`git diff --stat` contra `origin/main`, sem `assets/` nem `e2e/` alterados):

| Arquivo | Mudança |
|---|---|
| `live/task_live/node_panel.ex` | o link da issue lê `@task.source_url`; mesmo markup, texto e `data-testid="task-issue"` |
| `live/proposal_live/show.ex` | o link vem de `Proposals.origin_url/1`; mesmo markup e `data-testid="proposal-issue"` |
| `live/task_live/index.ex`, `proposal_request.ex` | o campo do formulário passa a ser `:source_url`; rótulo, placeholder, ajuda e `data-testid="task-issue-url"` iguais |
| `controllers/integration_webhook_controller.ex` | entrega pelo `TaskSources.receive_webhook/5`; respostas HTTP iguais |

Por isso não foram tiradas screenshots (`e2e.shots`): não há aparência nova a conferir, e o
plano já previa isso. Nenhum `data-testid` nem spec novo ou alterado.

## Verificação

- `make e2e.typecheck`: 0.
- Specs que tocam o que mudou (integrações, propostas do agente e tarefa), 7 testes, todos
  passam: `integrations-auto-merge`, `integrations-conversation`, `integrations-github`,
  `integrations-issue-to-task`, `integrations-setup`, `agent-proposals`, `task-pipeline`.
- Suíte e2e inteira, uma vez (`make e2e`): saiu 0, 37 testes passam.

Nenhum ajuste foi preciso.
