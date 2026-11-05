# Plano — O projeto como a única escolha de onde o trabalho roda

> **Status: bloqueado.** A tarefa pede quatro decisões de produto antes de implementar
> (seção "Decisões em aberto"). O plano abaixo marca onde cada resposta muda a solução.
> Base: `origin/main` em `0cde6a9` (fast-forward, sem commits alheios).

## Entendimento

Hoje o projeto (`PipeMaestro.Projects.Project`) é a configuração de um *nome de pasta*,
casado em qualquer runner (ADR 0008). A ligação com o trabalho é implícita:
`Tasks.create_task/4` → `put_directory/2` valida runner+pasta escolhidos à mão e
`put_project/2` procura `Projects.for_directory/2` em silêncio. Propostas fazem o mesmo em
`Proposals.scratch_context/2`; o webhook (`GithubWebhookController.online_runner/3`)
escolhe qualquer runner online que ofereça a pasta.

O modelo novo: **projeto = runner + pasta + configuração**, e é a única escolha de quem
dispara trabalho. Para quem usa:

- Projetos: criar escolhendo runner e pasta (à mão ou "analisar com IA", que preenche o
  formulário para revisão); trocar o runner por outro que ofereça a mesma pasta; ver
  runner, online/offline, "precisa de um runner", "o runner não oferece mais a pasta",
  tarefas recentes e atalhos "nova tarefa" / "nova execução".
- Nova tarefa, execução solta, tarefa escrita com IA e propostas: só um seletor de projeto.
- Tarefa, board, decisões, PRs, propostas, pipelines e uso mostram/filtram por projeto.

### Critérios de aceite (verificáveis)

1. Criar projeto exige `runner_id` + `directory` oferecido por ele; inválido → erro no
   changeset.
2. "Analisar com IA" cria um job de proposta `project` (scratch) e o resultado abre o
   formulário preenchido (nome, setup, teste, lint, pastas copiadas, notas); nada é
   gravado até "Salvar".
3. Trocar o runner do projeto só aceita runner ativo do workspace que oferece a pasta; a
   troca gera `project.runner_switched` na auditoria (`from`/`to`).
4. `Tasks.create_task/4` recebe `project_id`; runner, pasta, `git` e retrato saem do
   projeto. Sem `project_id` → erro (salvo a decisão 2). Tarefas antigas mantêm
   `project`/`directory`/`runner_id` gravados.
5. Execução solta (`JobsLive`) escolhe só projeto; o job vai ao runner do projeto, na
   pasta dele (modo conforme decisão 1).
6. Tarefa com IA e propostas `task`/`decision`/`analysis`/`improve` recebem só
   `project_id`; não existe mais `proposal-request-runner`/`proposal-request-directory`.
7. `Tasks.create_from_issue/3` e `Proposals.triage_issue/3` usam o runner do projeto (sem
   `online_runner/3`); projeto sem runner → 422 com mensagem clara.
8. Projeto com runner offline aceita tarefa: ela fica na fila com aviso "aguardando o
   runner X ficar online" na tela da tarefa e no board (nunca erro).
9. Migração: cada projeto existente recebe um runner ativo que ofereça a pasta (o visto
   por último); sem nenhum, `runner_id` nulo e a tela mostra "precisa de um runner", e
   o projeto não aceita trabalho até ter um.
10. Board filtra por projeto (`board-filter-project`); cards de board, decisões, PRs e
    propostas mostram o projeto; propostas filtram por projeto.
11. Tela da tarefa mostra o projeto com link e o retrato (setup, teste, lint, pastas).
12. Pipelines usam o projeto da última tarefa (`project_id`), ou nenhum.
13. Uso agrupa custo por projeto.
14. `Tasks.switch_runner` (ADR 0032) continua igual para tarefas paradas.

## Mudanças por app

### `apps/pipe_maestro` (domínio)

**Migrações** (`priv/repo/migrations/`):
- `projects.runner_id` (FK `runners`, `on_delete: :nilify_all`, nulo permitido para
  "precisa de um runner").
- Migração de dados: para cada projeto, o runner não revogado do workspace cujo
  `directories` contém a pasta, preferindo o `last_seen_at` mais recente. Feita em SQL
  (`jsonb_array_elements`), sem chamar módulos do app.
- Índice único: hoje `projects_workspace_id_directory_index`. **Decisão 3**: manter, ou
  trocar por `(workspace_id, runner_id, directory)`.
- `jobs.project_id` (FK, nulo): para a execução solta e as propostas mostrarem/filtrarem
  o projeto e o uso agrupar o custo delas. Backfill: jobs de etapa herdam de
  `tasks.project_id`; propostas pelo `context->proposal->input->directory` casado com o
  projeto único da pasta (se houver).

**`PipeMaestro.Projects` / `Project`:**
- `Project` ganha `belongs_to :runner`; changeset valida pasta oferecida pelo runner
  (`Runners` lê `runner.directories`), mantendo `Hello.valid_directory_name?/1`.
- `create_project/3` passa a exigir runner; `switch_runner(project, runner_id, user)`
  valida e grava `Audit.record(..., "project.runner_switched", ...)`.
- `runner_choices(project)`: runners ativos que oferecem a pasta.
- `health(project, online_ids)` → `:ok | :needs_runner | :runner_offline |
  :directory_gone` (lógica fora da LiveView).
- `for_directory/2` sai dos caminhos de criação; fica só para a migração de dados das
  propostas, se ainda servir, ou é removida.
- `recent_tasks(project, n)` via `Tasks`.

**`PipeMaestro.Tasks`:**
- `Task.create_changeset` passa a castar `project_id` (não mais `runner_id`/`directory`
  vindos do formulário). `put_directory/2` + `put_project/2` viram `put_project/2`, que
  carrega o projeto do workspace, exige `runner_id`, confere que o runner oferece a pasta
  (para `git`) e grava `runner_id`, `directory`, `git`, `project_id`, `project`.
- Runner offline: hoje `start_or_queue/1` já entrega o job pelo canal quando o runner
  conecta? Conferir na implementação: se o job fica `queued` e é reenviado no `join`,
  só falta o aviso na tela (`Tasks.waiting_for_runner?/2`, análogo a `runner_offline?/2`).
- `create_from_issue/3` (sem `runner_id`), `duplicate_params/1` e `rerun/2` usam
  `project_id`. Projeto apagado → `rerun` mostra erro "o projeto não existe mais".
- Filtro `{"project_id", id}` em `list_tasks` substitui `{"directory", dir}`.
- `history/2` já devolve tarefas; o pipeline usa `task.project_id`.

**`PipeMaestro.Jobs`:** `create_job/4` aceita `project_id`; deriva `runner_id`,
`context["directory"]` e, conforme a **decisão 1**, `scratch` + `setup` do retrato.
`Job` ganha `belongs_to :project`.

**`PipeMaestro.Proposals`:**
- Novo `PipeMaestro.Proposals.ProjectKind` (`name "project"`, em `@kinds` e
  `kinds/0`): entrada `project_id` *ou* `runner_id`+`directory` (o projeto ainda não
  existe), `request` opcional, `feedback`. Esquema da resposta: `analise`, `verificacoes`,
  `projeto` (`nome`, `setup`, `teste`, `lint`, `copiar`, `notas`).
- `Instructions.study_project/0` e o trecho `projeto` do schema de `PipelineKind` saem
  para um lugar comum (`Instructions` ou `ProjectKind.project_schema/0`).
- `request/5` e `validate_runner/2`: as kinds de trabalho recebem `project_id` e a
  função resolve runner/pasta do projeto (`scratch_context/2` passa a receber o projeto,
  não a pasta). Só `ProjectKind` aceita runner+pasta soltos.
- `PipelineKind`: **decisão 4** — passa a exigir `project_id` (e deixa de propor o
  projeto) ou mantém o bloco do projeto.
- `triage_issue/3` usa o runner do projeto. `list/3` filtra por `project_id`.

**`PipeMaestro.Usage`:** `report/3` ganha o grupo `by_project` (join `jobs.project_id`
→ `projects.name`, com "sem projeto" para os antigos/soltos), e o filtro por projeto.

**`PipeMaestro.Pipelines`:** sem mudança de schema.

### `apps/pipe_maestro_web`

| Arquivo | Mudança |
|---|---|
| `live/project_live/form.ex` | Seletor de runner (`project-runner`) e de pasta oferecida (`project-directory`, `select` dependente); botão "Analisar com IA" (`project-analyze`) que dispara `ProjectKind` e navega para a proposta; ao voltar, formulário preenchido. Na edição, "Trocar runner" (`project-switch-runner`). |
| `live/project_live/index.ex` | Por projeto: runner + selo online (`project-runner-<slug>`, `project-status-<slug>`), avisos `project-needs-runner-<slug>` e `project-directory-gone-<slug>`, tarefas recentes (`project-recent-tasks-<slug>`), atalhos `project-new-task-<slug>` / `project-new-job-<slug>` (→ `/tasks/new?project_id=` e `/jobs?project_id=`). |
| `live/proposal_live/show.ex` | Resultado `project`: formulário `proposal-project-form` preenchido, salva via `Projects.create_project/3` com runner+pasta do input. O tipo `pipeline` segue a decisão 4. |
| `live/proposal_live/index.ex` | `proposals-directory` → `proposals-project`; cards mostram o projeto. |
| `proposal_request.ex` | Sai runner/pasta; entra `proposal-request-project` (projetos com runner, git e capaz de scratch; os demais desabilitados com o motivo). |
| `live/task_live/index.ex` | Sai `task-runner`, `task-directory`, `directory_options/2`; entra `task-project`. Aviso `task-project-offline` quando o runner está offline (a tarefa espera). |
| `live/task_live/show.ex` | `runner:pasta` → projeto com link (`task-project`) e bloco do retrato (`task-project-snapshot`); aviso `task-waiting-runner`. O troca-runner da ADR 0032 fica. |
| `live/jobs_live.ex` | `job-runner` → `job-project`; opcional `job-mode` (decisão 1). |
| `live/board_live.ex` | `board-filter-directory` → `board-filter-project`; card mostra `board-card-project`. |
| `live/decisions_live.ex`, `live/pull_requests_live.ex` | Cards mostram o projeto (`*-project`). |
| `live/pipeline_live/index.ex` | `pipeline_directory/2` → projeto da última tarefa, ou nenhum. |
| `live/usage_live.ex` | Tabela "Por projeto" (`usage-by-project`). |
| `controllers/github_webhook_controller.ex` | Sai `online_runner/3`: usa `project.runner_id`; sem runner → 422 "o projeto precisa de um runner". Triagem com runner offline: o job espera (mesma regra). |

Componentes Petal (conferir attrs em `docs/guias/ui-petal.md`): `<.field type="select">`
para projeto/runner/pasta, `<.badge>` para online/offline/"precisa de um runner",
`<.alert>` para os avisos, `<.button>`/`<.link>` para atalhos, `<.card>` nos cards.
Channels: nenhum evento novo; `RunnerStatus` continua fonte de "online".

### `apps/pipe_maestro_protocol` — **não muda**

O `Job` já cobre todos os casos: sem `directory` (workdir), `directory` direto,
`directory` + `scratch`, e tarefa com `worktree`. O projeto não viaja no fio; só o
runner e a pasta que já viajam. Versão segue 4.

### `apps/pipe_maestro_runner` — **não muda**

`JobRunner.place/1` já trata `:workdir`, `{:directory, d}`, `{:scratch, id}` e tarefa.

## Fronteiras

- Runner continua dependendo só de `protocol`; nada novo nele.
- Domínio sem web: `health/2` recebe os ids online como argumento (como
  `Tasks.alerts/2` e `runner_offline?/2` já fazem), sem chamar `PipeMaestroWeb.RunnerStatus`.
- `ProjectKind` fica no domínio; a LiveView só abre e lê a proposta.

## Protocolo

Não toca `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels.
`docs/specs/protocolo-runner.md` não muda; a versão não sobe; runners antigos (na
versão 4) seguem compatíveis. Ressalva: se a decisão 1 for "scratch", o projeto da
execução precisa de runner com a capacidade `"scratch"` (já anunciada pelos runners da
versão 4); a tela desabilita o projeto com o motivo, como `ProposalRequest` já faz.

## Testes

ExUnit (`apps/pipe_maestro/test`):
- `projects_test.exs`: criar com runner que oferece/não oferece a pasta; unicidade
  (decisão 3); `switch_runner/3` válido, inválido e auditoria; `health/2` nos quatro
  estados.
- Migração de dados: teste com projetos e runners semeados, chamando a função de
  backfill (extraída para um módulo `@moduledoc false` testável ou testada via SQL).
- `tasks_test.exs`: `create_task` com `project_id` grava runner/pasta/git/retrato; sem
  projeto → erro; projeto sem runner → erro; runner offline → tarefa criada e na fila;
  `create_from_issue/3`; `rerun` com projeto apagado; filtro `project_id`; retrato
  antigo intacto.
- `jobs_test.exs`: execução solta por projeto (diretório/scratch conforme decisão 1).
- `proposals_test.exs` + `project_kind_test.exs`: request com runner+pasta; schema;
  kinds de trabalho por `project_id`; triagem pelo runner do projeto.
- `usage_test.exs`: grupo por projeto.

Web (`apps/pipe_maestro_web/test`): LiveView tests para cada tela da tabela acima e o
webhook (projeto sem runner → 422).

Playwright (`e2e/tests/`):
- `projects.spec.ts` (novo): criar à mão; criar com IA aprovando o formulário
  preenchido (runner fake de e2e com capacidade scratch, como `pipeline-proposal.spec.ts`);
  trocar o runner.
- `task-pipeline.spec.ts`: nova tarefa escolhendo só o projeto.
- `job-execution.spec.ts`: execução solta escolhendo só o projeto.
- `board-alerts.spec.ts` (ou `board-project-filter.spec.ts`): filtro por projeto.
- `agent-proposals.spec.ts` / `pipeline-proposal.spec.ts`: seletores atualizados.
- `make e2e.shots`, claro e escuro, auditados.

## Documentação

- **ADR 0034** "O projeto é runner + pasta e a escolha única das execuções",
  complementando a 0008 (e citando 0021/0022 para o tipo `project` e 0032 para a troca
  de runner da tarefa). Registra as quatro decisões.
- `docs/specs/maquina-de-estados-tarefa.md`: a tarefa nasce de um projeto; espera de
  runner offline.
- `docs/plano/` e guias que citam "runner e diretório" na criação de tarefa: atualizar
  (procurar por `directory`/"diretório" ao implementar). `e2e/README.md` se surgirem
  convenções novas de test id.

## Riscos

- **Migração de dados**: pastas que nenhum runner oferece → `runner_id` nulo; pastas
  oferecidas por vários → escolha do mais recente (registrar no ADR). Runners revogados
  ignorados. Reversível (drop da coluna).
- **Unicidade (decisão 3)**: se dois projetos puderem ter a mesma pasta, tudo que hoje
  filtra por `directory` (board, propostas, `scratch_context`) precisa ir para
  `project_id`, sem fallback por nome; propostas antigas sem `project_id` ficam "sem
  projeto" no filtro.
- **Concorrência**: troca de runner do projeto com tarefas em andamento não afeta essas
  tarefas (têm `runner_id` próprio); só o trabalho novo. Documentar.
- **Fila de runner offline**: conferir que o job fica `queued` e é reentregue no join;
  se não, é preciso mexer em `Jobs`/canal (sem tocar o protocolo).
- **Cobertura**: muitas telas mudam; manter testes LiveView por tela para não cair sob
  60%. **Dialyzer**: specs novas em `Projects`, `Tasks`, `Jobs`, `ProjectKind`.
- **Tamanho**: a mudança cruza domínio e web; pode valer separar em PRs (domínio +
  migração; telas de criação; telas de exibição; uso/ADR).

## Decisões em aberto (perguntadas)

1. Execução solta num projeto: direto na pasta, worktree descartável (scratch), ou
   escolha por execução?
2. Existe "sem projeto" (ex.: execução solta no workdir do runner) ou todo trabalho exige
   projeto?
3. A pasta continua única por workspace, ou dois projetos podem ter a mesma pasta em
   runners diferentes?
4. O tipo de proposta `pipeline` passa a exigir um projeto existente, ou continua
   oferecendo criar o projeto no mesmo fluxo?
