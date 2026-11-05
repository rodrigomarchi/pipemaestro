# 03 — Implementação: pipeline escolhido e auto-aprovação da tarefa escrita com IA

Os testes da etapa 2 passam sem mudanças, exceto por um ajuste no page object do e2e,
explicado abaixo. `make ci.quick` sai 0, `mix dialyzer` passa sem erros e
`make e2e.shots` passa (22/22).

## O que mudou

### `apps/pipe_maestro` (domínio)

- **Migração** `priv/repo/migrations/20261111090000_add_proposal_job_to_tasks.exs`: cria
  `tasks.proposal_job_id` (FK para `jobs`, `on_delete: :nilify_all`) e um índice único parcial
  (`WHERE proposal_job_id IS NOT NULL`).
- **`Tasks.Task`**: `belongs_to :proposal_job`, fora do `cast`.
  `unique_constraint(:proposal_job_id, message: "esta proposta já virou uma tarefa")`.
- **`Tasks.create_task/4`**: recebe `opts`. Com `proposal: job`, o vínculo vai direto na struct.
  Sem `opts`, faz o mesmo que antes.
- **`Proposals.TaskKind`**:
  - novos campos `pipeline_id`, validado com `Pipelines.get_pipeline/2` ("não é um pipeline
    deste workspace"), e `auto_approve`, sem default: ausente fica desligado;
  - com um pipeline escolhido, o prompt cita só esse pipeline, e `result/2` o usa em
    `pipeline`, `pipeline_name` e `task_params`. Se ele foi apagado, vale a sugestão do agente;
  - `result/2` também devolve `auto_approve`.
- **`Proposals`**:
  - `create_task/4` é o único caminho para criar uma tarefa a partir de uma proposta. Grava
    `created_task_id` no contexto;
  - `created_task_id/1` lê o contexto ou, se não houver, a coluna;
  - `auto_approve/1`;
  - `job_finished/1`: só age em proposta `task` que terminou bem, tem `auto_approve` e
    ainda não tem tarefa. Cria a tarefa em nome de quem pediu e registra
    `task.auto_created` no `Audit`. Quando não cria, guarda o motivo: tarefa não pronta (com as
    perguntas), nenhum pipeline, quem pediu fora do workspace, ou os erros do changeset. O erro
    de unicidade, de uma criação concorrente, não é tratado como motivo. Nada usa `!` nesse
    caminho.
- **`Jobs`**:
  - `finished/1` ganhou a cláusula das propostas `task`, que chama `Proposals.job_finished/1`;
  - nova `update_proposal/2`, que faz o merge no `context["proposal"]` sob `FOR UPDATE` e
    notifica `{:job_updated, job}`.

### `apps/pipe_maestro_web`

- **`ProposalRequest`**: para tarefas, o modal ganhou o select de pipeline
  (`proposal-request-pipeline`, "Deixar o agente escolher" com valor vazio) e o switch
  `<.field type="switch">` do Petal (`proposal-request-auto-approve`), ligado por padrão por
  `kind_defaults("task")`. Também mudaram o texto de introdução e o `@type t`, que ganhou
  `pipelines`.
- **`ProposalLive.Show`**:
  - `proposal-created-task-link` aparece no lugar de `proposal-create-task` quando a tarefa
    já existe;
  - `<.alert color="warning">` (`proposal-auto-approve-skipped`) mostra o motivo de não ter
    criado a tarefa;
  - com a página aberta, quem pediu é levado à tarefa quando ela nasce
    (`follow_created_task/2`).
- **`TaskLive.Index`**:
  - `?proposta=` de uma proposta que já virou tarefa leva até a tarefa;
  - o formulário de uma proposta cria a tarefa por `Proposals.create_task/4`. O erro de
    unicidade também leva à tarefa.
- **`TaskLive.Show`**: `data-testid="task-pipeline-name"`, usado pelo e2e.
- **`AuditLive`**: novo rótulo "Tarefa criada automaticamente da proposta".

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`

Nada mudou. O protocolo continua igual: os dados novos ficam em `context["proposal"]`, que
não chega ao runner. Por isso não há tratamento de runner antigo.

### Documentação

- `docs/adr/0031-auto-aprovacao-da-tarefa-escrita-com-ia.md` (nova).
- `docs/adr/0022-…`: a tabela de tipos aponta para a ADR 0031.
- `docs/specs/maquina-de-estados-tarefa.md`: explica a origem de uma tarefa numa proposta e o
  `proposal_job_id`.

## Ajuste em teste

`e2e/pages/ProposalPage.ts`: o `setChecked` agora usa `{ force: true }`. O switch do Petal põe
o `<input>` em `sr-only` sob o `<label class="pc-switch">`, e o Playwright recusava o clique
porque "label intercepts pointer events". Com `force`, o clique cai no label, que alterna o
input. O `setChecked` continua conferindo o estado final, então o teste não ficou mais fraco.

## Como verificar

```sh
mix test apps/pipe_maestro/test/pipe_maestro/proposals_test.exs apps/pipe_maestro/test/pipe_maestro/tasks_test.exs
mix test apps/pipe_maestro_web/test/pipe_maestro_web/live/proposal_live_test.exs
make ci.quick > /tmp/ciq.log 2>&1; echo $?   # 0
mix dialyzer                                  # 0 erros
make e2e.shots                                # 22 passed
```

Screenshots auditados, claro e escuro, em
`e2e/screenshots/agent-proposals/the-agent-writes-a-task-…/`:
- `02-task-proposal-request`: select e switch ligado;
- `05-task-proposal-auto-created`: botão "Abrir a tarefa", pipeline "Correção de bug";
- `06-task-proposal-auto-skipped`: aviso amarelo com o motivo e a pergunta.

O `make ci` completo não foi rodado de uma vez. Rodei as duas metades, que passaram:
`ci.quick` e `dialyzer`.
