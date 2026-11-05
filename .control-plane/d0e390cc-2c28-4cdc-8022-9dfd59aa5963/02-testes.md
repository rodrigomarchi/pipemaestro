# Testes que falham — O projeto como a única escolha de onde o trabalho roda

Base: plano em `01-plano.md` (critérios 1–14 e as quatro decisões). Só testes foram
escritos; nenhum código de produção mudou.

## Resultado

| Suíte | Resultado |
|---|---|
| Testes novos do domínio (`apps/pipe_maestro`) | **0/51 passam** — todos falham pelo comportamento ausente |
| Testes novos da web (`apps/pipe_maestro_web`) | **0/22 passam** — idem |
| Suíte inteira (`mix test` na raiz) | domínio 267/318, web 299/321, protocolo 77/77, runner 187/187: **as 51 + 22 falhas são exatamente as dos arquivos novos**; os testes que já existiam continuam passando |
| `make e2e.typecheck` | passa (o spec e os page objects compilam) |
| `mix format --check-formatted` | passa |

Nenhum teste falha por sintaxe ou por setup: os arquivos compilam (há só *avisos* de
função/campo ainda inexistentes, como `Projects.switch_runner/3` e `job.project_id`).

## Arquivos

### Domínio — `apps/pipe_maestro/test/pipe_maestro/`

- `projects/project_runner_test.exs` (critérios 1, 3, 9, decisão 3, `github_repo` único):
  criar exige runner do workspace que ofereça a pasta; runner de outro workspace ou
  revogado recusado; mesma pasta em runners diferentes aceita, duas vezes no mesmo runner
  recusada ("esse runner já tem um projeto nessa pasta"); `github_repo` único por
  workspace ("outro projeto já usa esse repositório"); `switch_runner/3` (válido com
  auditoria `project.runner_switched` `from`/`to`, runner sem a pasta, runner que já tem
  projeto na pasta, tarefas já iniciadas mantêm o runner); `runner_choices/1`;
  `health/2` (`:ok`, `:runner_offline`, `:directory_gone`, `:needs_runner` quando o runner
  é apagado — FK `on_delete: :nilify_all`); `scratch_context/1`; `recent_tasks/2`.
- `tasks/task_from_project_test.exs` (critérios 4, 7, 8, 14): `create_task/4` com
  `project_id` grava runner, pasta, `git`, retrato e o `project_id` do job; runner/pasta do
  formulário ignorados; sem projeto → "escolha um projeto"; projeto de outro workspace ou
  apagado → "o projeto não existe mais"; sem runner → "o projeto precisa de um runner";
  runner que não oferece mais a pasta → erro em `directory`; pasta sem git → `git: false`;
  runner offline → tarefa criada, job `queued` em `Jobs.queued_for_runner/1` e
  `Tasks.waiting_for_runner?/2`; filtro `"project_id"` em `list_tasks/2`;
  `duplicate_params/1` com `project_id`; `rerun/2` de projeto apagado explica;
  `create_from_issue/3` usa o runner do projeto, e sem runner devolve o erro.
- `jobs/job_from_project_test.exs` (critério 5, decisões 1 e 2): `create_job/3` com
  `project_id` vai ao runner do projeto, `scratch: true`, `directory` e `setup` do projeto,
  `job.project_id`; runner do formulário ignorado; sem projeto, projeto de outro workspace,
  pasta sem git ("a pasta do projeto não é um repositório git"), runner sem `scratch`
  ("o runner precisa ser atualizado") e projeto sem runner recusados; runner offline →
  job na fila do runner.
- `proposals/project_kind_test.exs` (critérios 2, 6, 7, decisão 4): `"project"` em
  `Proposals.kinds/0` e `ProjectKind`; pedido com `runner_id` + `directory` (sem projeto
  ainda), scratch, `$comment` `pipemaestro-kind:project`; pasta sem git e runner sem
  `scratch` recusados; o resultado vira os atributos do formulário com `runner_id` e
  `directory` e nada é gravado; `ProjectKind.schema/0`; `task` só por `project_id` (job,
  contexto, `task_params` com `project_id`); runner + pasta soltos → "escolha um projeto";
  projeto sem runner recusado; `pipeline` exige `project_id`, seu schema perde `projeto`
  e uma resposta antiga com `projeto` ainda é lida; `Proposals.list/3` filtra por
  `project_id`; `triage_issue/3` usa o runner do projeto.
- `usage/by_project_test.exs` (critério 13): `report/3` ganha `by_project` com
  "sem projeto" para jobs antigos, e o filtro `"project_id"`.

### Web — `apps/pipe_maestro_web/test/pipe_maestro_web/`

- `controllers/github_webhook_project_test.exs` (critérios 7, 8): a issue vira tarefa
  no runner do projeto mesmo offline (job na fila); triagem idem; projeto sem runner →
  422 `"o projeto precisa de um runner"` (tarefa e triagem).
- `live/project_live_runner_test.exs` (critérios 1, 2, 3, 9): formulário com
  `project-runner` e `project-directory` dependente; sem runner → "escolha o runner do
  projeto"; `project-analyze` cria a proposta `project` e navega para ela; edição com
  `#project-switch-runner-form` / `project-switch-runner`; proposta `project` com
  `#proposal-project-form`, que salva o projeto com o runner e a pasta pedidos e volta
  para `/projects`; lista com `project-runner-<pasta>`, `project-status-<pasta>`
  (online/offline), `project-recent-tasks-<pasta>`, `project-new-task-<pasta>` →
  `/tasks?project_id=…`, `project-new-job-<pasta>` → `/jobs?project_id=…`,
  `project-needs-runner-<pasta>` e `project-directory-gone-<pasta>`.
- `live/work_by_project_live_test.exs` (critérios 4, 5, 8, 10, 11, 13): nova tarefa só
  com `task-project` (sem `task-runner`/`task-directory`), `?project_id=` pré-seleciona,
  aviso `task-project-offline`; tela da tarefa com `task-project` (link) e
  `task-project-snapshot`, aviso `task-waiting-runner`; execução solta só com
  `job-project` (projeto sem git desabilitado com o motivo), `?project_id=`, aviso
  `job-project-offline`; board com `board-filter-project` e `board-card-project`; uso com
  `usage-by-project`.

### Playwright — `e2e/`

- `tests/projects.spec.ts` (novo, `@section Projetos`, fluxos A–C `[todo]`): criar à mão
  escolhendo runner e pasta; "analisar com IA" e revisar o formulário preenchido antes de
  salvar; atalho "nova tarefa" do projeto, formulário sem runner/pasta, tarefa mostrando
  projeto e retrato.
- `pages/ProjectsPage.ts`: `create` aceita `runner`; novos `pickRunner`, `analyze`,
  `runner`, `status`, `newTask`.
- `pages/ProposalPage.ts`: novo `saveProposedProject` (proposta `project` → `/projects`).

`make e2e.typecheck` passa. O spec não foi executado (não é preciso rodar o e2e nesta
etapa); ele falha no fluxo A, em `pickRunner`, porque `project-runner` ainda não existe.
**Para a implementação:** o `fake_claude` do runner
(`apps/pipe_maestro_runner/test/support/fake_claude`) precisa responder ao
`pipemaestro-kind:project` com `analise`, `verificacoes` e `projeto` ("App do fake",
`make test`, `deps`), como já faz para `pipeline`. Os specs existentes
(`task-pipeline`, `job-execution`, `board-alerts`, `agent-proposals`,
`pipeline-proposal`) também precisam dos seletores novos.

## Por que cada falha é a esperada

Saída completa em `mix test <arquivos>` (domínio e web). Agrupadas por motivo:

**Função ou módulo que ainda não existe** (`UndefinedFunctionError`):
```
** (UndefinedFunctionError) function PipeMaestro.Projects.switch_runner/3 is undefined or private
** (UndefinedFunctionError) function PipeMaestro.Projects.health/2 is undefined or private
** (UndefinedFunctionError) function PipeMaestro.Projects.runner_choices/1 is undefined or private
** (UndefinedFunctionError) function PipeMaestro.Projects.scratch_context/1 is undefined or private
** (UndefinedFunctionError) function PipeMaestro.Tasks.create_from_issue/3 is undefined or private
** (UndefinedFunctionError) function PipeMaestro.Proposals.triage_issue/3 is undefined or private
** (UndefinedFunctionError) function PipeMaestro.Proposals.ProjectKind.schema/0 is undefined (module PipeMaestro.Proposals.ProjectKind is not available)
```
São as funções públicas novas do plano.

**O projeto ainda não tem runner** (`projects.runner_id` não existe):
```
** (KeyError) key :runner_id not found in: %PipeMaestro.Projects.Project{...}
code:  assert {:error, changeset} = Projects.create_project(... sem runner_id) | right: {:ok, ...}
code:  assert {:ok, on_server} = Projects.create_project(ctx.workspace, attrs(ctx.server)) | right: {:error, ...}   # índice único ainda é (workspace, directory)
code:  assert %{github_repo: ["outro projeto já usa esse repositório"]} = ... | right: %{directory: ["já tem um projeto"]}
```

**Tarefa, job e proposta ainda pedem runner e pasta, não projeto**:
```
code:  assert {:ok, task} = Tasks.create_task(ctx.user, ctx.workspace, params(ctx)) | right: {:error, ...
  errors: [directory: {"escolha um diretório do runner", ...}, runner_id: {"escolha um runner online", ...}]
code:  assert %{project_id: ["o projeto precisa de um runner"]} = errors_on(changeset) | right: %{runner_id: ["escolha um runner online"]}
code:  assert %{project_id: ["a pasta do projeto não é um repositório git"]} = ... | right: %{runner_id: ["escolha um runner online"]}
code:  assert {task.runner_id, task.directory} == {ctx.runner.id, "app"}   # o runner do formulário ainda vale
code:  assert job.runner_id == ctx.runner.id                               # idem para o job
code:  assert {:error, changeset} = Jobs.create_job(... só runner_id) | right: {:ok, ...}   # job sem projeto ainda aceito
code:  assert {:error, changeset} = Proposals.request("pipeline", ... runner_id + directory) | right: {:ok, ...}
```
Os `MatchError` de setup em `list_tasks`, `recent_tasks`, `rerun`, `usage` e nas telas
vêm do mesmo ponto: `create_task`/`create_job` com `project_id` devolvem
`{:error, changeset}` com `runner_id`/`directory` obrigatórios.

**O tipo `project` não existe**:
```
Assertion with in failed | code: assert "project" in Proposals.kinds() | right: ["pipeline", "task", "decision", "analysis", "improve"]
** (KeyError) key "project" not found in: %{"analysis" => ..., "pipeline" => ...}
```

**Webhook ainda procura runner online**:
```
expected response with status 201, got: 422 ... "nenhum runner online oferece o diretório app"
code: assert %{"error" => "o projeto precisa de um runner"} = json_response(conn, 422) | right: %{"error" => "nenhum runner online oferece o diretório app"}
```

**Telas ainda sem os elementos novos**:
```
expected selector "[data-testid=project-runner]" to return a single element, but got none
could not find non-disabled input, select or textarea with name "project[runner_id]"
expected selector "[data-testid=project-switch-runner]" to return a single element, but got none
code: assert has_element?(view, "[data-testid=project-needs-runner-app]")
code: assert has_element?(view, "[data-testid=project-directory-gone-app]")
code: refute has_element?(view, "[data-testid=task-runner]")
code: refute has_element?(view, "[data-testid=job-runner]")
could not find non-disabled input, select or textarea with name "task[project_id]"
element selected by "#new-job-form" does not have phx-change attribute   # o aviso de runner offline precisa reagir à escolha
code: assert has_element?(view, "[data-testid=task-project] option[selected][value='…']")
```

## Escolhas feitas nos testes (para a implementação seguir)

- **Mensagens de erro**: "escolha um projeto", "o projeto não existe mais" (id que não é
  do workspace ou foi apagado), "o projeto precisa de um runner", "o runner não oferece
  esse diretório", "esse runner já tem um projeto nessa pasta", "outro projeto já usa
  esse repositório", "a pasta do projeto não é um repositório git", "o runner precisa ser
  atualizado", "escolha o runner do projeto" (formulário).
- **Atalhos**: `/tasks?project_id=` e `/jobs?project_id=`, nas rotas que já existem
  (`TaskLive.Index` já trata parâmetros como `?duplicate=`), em vez de um `/tasks/new`
  novo.
- **Test ids por projeto** continuam com a pasta como chave (`project-<pasta>`,
  `project-runner-<pasta>` …), como hoje. Com a decisão 3 dois projetos podem ter a mesma
  pasta em runners diferentes; os testes nunca mostram os dois na mesma lista. Se a
  implementação precisar de chave única nesse caso, ajuste `e2e/README.md` e os testes.
- **Backfill da migração** (critério 9) não tem teste aqui: o plano deixa em aberto se
  vira módulo testável ou SQL puro. A implementação deve testá-lo onde ficar.
- Os testes que já existiam e usam `runner_id`/`directory` (ex.: `tasks_test.exs`,
  `job_fixture/3`, `project_live_test.exs`, `github_webhook_controller_test.exs`)
  continuam no contrato antigo e passam hoje; a implementação os migra para `project_id`.
