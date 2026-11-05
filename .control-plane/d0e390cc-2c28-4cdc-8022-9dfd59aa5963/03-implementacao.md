# Implementação — O projeto como a única escolha de onde o trabalho roda

Base: `01-plano.md` (critérios 1–14, decisões 1–4) e os testes de `02-testes.md`.

## Resultado

| Verificação | Resultado |
|---|---|
| Testes novos da etapa 2 (domínio: 51, web: 22) | **todos passam**, sem enfraquecer nenhum (dois ajustes justificados abaixo) |
| `mix test` (domínio / web / protocolo / runner) | 321 / 321 / 77 / 187, todos passam |
| `make ci.quick` | **sai 0** (compile sem avisos, format, deps, credo strict, testes com cobertura) |
| `mix dialyzer` (raiz) | **passa**, 0 erros |
| `make e2e.typecheck` / `make e2e` / `make e2e.shots` | **pendente**: page objects migrados em parte, specs ainda não (ver "Pendências") |

## O que mudou, por app

### `apps/pipe_maestro` (domínio)

- **Migração** `20261112090000_add_runner_to_projects.exs`: `projects.runner_id` (FK,
  `on_delete: :nilify_all`); backfill pelo runner ativo que oferece a pasta, o visto por
  último; índice único passa a `(workspace_id, runner_id, directory)`; `github_repo` único
  por workspace (índice parcial; a migração aborta com mensagem se houver duplicata);
  `jobs.project_id` (FK) com backfill pela tarefa ou pelo único projeto da pasta. O SQL do
  backfill fica em funções públicas da migração, testadas em
  `test/pipe_maestro/projects/runner_backfill_test.exs`. `down` desfaz tudo (testado com
  rollback + migrate).
- **`Projects.Project`**: `belongs_to :runner`; o changeset exige o runner ("escolha o
  runner do projeto"), confere que é ativo do workspace e oferece a pasta, e traz as
  mensagens novas de unicidade.
- **`Projects`**: `get_project/2`, `switch_runner/3` (auditoria `project.runner_switched`
  com `from`/`to`), `runner_choices/1`, `health/2` (`:ok | :needs_runner |
  :directory_gone | :runner_offline`), `scratch_context/1`, `recent_tasks/2`;
  `for_directory/2` saiu.
- **`Runners.Runner`**: `directory/2` e `offers?/2`.
- **`Tasks`**: `create_task/4` recebe `project_id` (runner, pasta, `git`, retrato saem do
  projeto; runner/pasta do formulário são ignorados); `create_from_issue/3`;
  `duplicate_params/1` e `rerun/2` por projeto ("o projeto não existe mais");
  filtro `"project_id"`; `waiting_for_runner?/2`; o job de etapa guarda `project_id`.
- **`Jobs`**: `create_job/3` só por projeto, sempre `scratch` com o setup do projeto
  (`project_ready/1` explica por que um projeto não serve); `create_runner_job/4` para os
  jobs que o control plane monta (propostas); `Job` ganha `belongs_to :project`.
- **`Proposals`**: novo `ProjectKind` (`project`, runner + pasta, formulário preenchido);
  `PipelineKind` exige projeto e não propõe mais o projeto (resposta antiga ainda lida);
  `task`/`improve` por `project_id`; `decision`/`analysis` seguem a tarefa e anotam o
  projeto; `triage_issue/3`; filtro `"project_id"`; `checks_schema/0` e `checks/1`
  compartilhados.
- **`Usage`/`Insights`**: grupo `by_project` ("sem projeto" para os antigos) e filtro
  `"project_id"`.

### `apps/pipe_maestro_web`

- `ProjectChoice` (novo): o select de projeto de toda tela que dispara trabalho, com os
  projetos que não servem desabilitados e o motivo, e o runner offline que o trabalho
  espera.
- Projetos: formulário com runner e pasta dependente, "Analisar com IA"
  (`project-analyze`), troca de runner (`#project-switch-runner-form`); lista com runner,
  online/offline, avisos de "precisa de um runner"/"não oferece mais a pasta", tarefas
  recentes e atalhos `/tasks?project_id=` e `/jobs?project_id=`.
- Nova tarefa (`task-project`, aviso `task-project-offline`), execução solta
  (`job-project`, `job-project-offline`, texto do worktree descartável), pedidos de
  proposta (`proposal-request-project`).
- Tarefa: projeto com link (`task-project`), retrato (`task-project-snapshot`) e
  `task-waiting-runner`; o alerta de tarefa parada fica para quando um job já começou.
- Proposta `project` com `#proposal-project-form`; a `pipeline` só abre o formulário do
  pipeline (`proposal-open-pipeline`).
- Board (`board-filter-project`, `board-card-project`), propostas (`proposals-project`,
  projeto no cartão), decisões e PRs (projeto no cartão), uso (`usage-by-project`),
  melhoria de pipeline a partir do projeto da última tarefa.
- Webhook do GitHub pelo runner do projeto; sem runner → 422 "o projeto precisa de um
  runner"; runner offline → o trabalho espera.
- `icon_field` aceita `disabled`.

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`

Protocolo intacto (sem versão nova). No runner, só o `fake_claude` de teste responde ao
`pipemaestro-kind:project` e a resposta de `pipeline` não traz mais `projeto`. Runner
antigo sem `"scratch"`: conecta e roda tarefas; os projetos dele aparecem desabilitados
para execução solta e propostas com "o runner precisa ser atualizado" (testado em
`job_from_project_test.exs` e `proposal_live_test.exs`).

### Documentação

ADR 0034; `docs/specs/maquina-de-estados-tarefa.md` (a tarefa nasce de um projeto, espera
de runner offline); `docs/guias/instalacao.md` (primeiro projeto e nova tarefa).

## Testes ajustados (e por quê)

- `project_live_runner_test.exs`, "analyse with AI": escolhia runner e pasta na mesma
  mudança do formulário. A pasta é um select que depende do runner, e o LiveViewTest
  recusa uma opção que ainda não existe; o teste agora escolhe o runner primeiro, como
  uma pessoa faria. O que ele verifica não mudou.
- `project_runner_test.exs`, `recent_tasks/2`: os timestamps têm precisão de segundo, e
  tarefas criadas no mesmo segundo empatavam (a ordem saía aleatória). O teste agora dá a
  cada tarefa um segundo de diferença; a expectativa (mais nova primeiro) é a mesma.
- Os testes antigos que criavam tarefas, jobs e propostas com `runner_id` + `directory`
  foram migrados para `project_id` (fixtures `project_fixture/3`, `projects_fixture/1`,
  `project_on/2`; `job_fixture/3` usa `create_runner_job/4`). Os que testavam o
  comportamento que deixou de existir (escolha de runner e pasta na nova tarefa, carga de
  cada runner no select, execução sem projeto) foram reescritos para o comportamento novo.

## Como verificar

```sh
make ci.quick > /tmp/ciq.log 2>&1; echo $?          # 0
cd apps/pipe_maestro && mix test test/pipe_maestro/projects test/pipe_maestro/tasks \
  test/pipe_maestro/jobs test/pipe_maestro/proposals test/pipe_maestro/usage
cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/live/project_live_runner_test.exs \
  test/pipe_maestro_web/live/work_by_project_live_test.exs \
  test/pipe_maestro_web/controllers/github_webhook_project_test.exs
```

## Pendências

**Playwright (`e2e/`) não está pronto.** Os page objects começaram a ser migrados
(`TasksPage`, `JobsPage`, `ProposalPage` e `ProjectsPage` escolhem o projeto; novo
`e2e/helpers/projectSelect.ts`), mas os specs ainda usam a API antiga, e
`make e2e.typecheck` falha (`runner`/`directory` em `tasks.create`, `submitRequest`,
`directoryOptions`, `saveProject`, `projects.create` sem `runner`). Falta:

1. em cada spec que dispara trabalho (`task-pipeline`, `decision-questionnaire`,
   `board-alerts`, `agent-proposals`, `pipeline-proposal`, `job-execution`,
   `runner-connection`), subir o runner com `--root` (`RunnerProcess.createCodeRoot()`),
   criar o projeto (`ProjectsPage.create({ name, runner, directory })`) e passar
   `project` em vez de `runner`/`directory`;
2. `job-execution` e `runner-connection` liam `fake-claude.txt` do `workdir` do runner:
   a execução solta agora roda num worktree descartável, então essas asserções
   precisam olhar o que é observável na tela (o fluxo A do `@flow` também muda de texto);
3. `pipeline-proposal`: a proposta não salva mais o projeto; usar
   `proposal-open-pipeline` (o `ProposalPage.saveProject` virou abrir o pipeline);
4. rodar `make e2e` e `make e2e.shots` e auditar as telas novas (lista e formulário de
   projetos, modais de nova tarefa e de execução, tarefa, board) claro e escuro.

Nenhum app mudou por causa do e2e; o `fake_claude` já responde ao tipo `project`.
