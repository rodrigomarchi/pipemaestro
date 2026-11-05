# 01 — Plano: escolher o pipeline e auto-aprovar a tarefa escrita com IA

Branch: `cp/escolher-o-pipeline-e-auto-aprovar-ligad-99cddcb4`, atualizada por fast-forward
até `origin/main` (`979176e`). Não há commits desta tarefa ainda.

## Entendimento

Hoje, em **Tarefas → Escrever com IA**, o agente escreve a tarefa (`PipeMaestro.Proposals.TaskKind`)
e sugere um pipeline. Depois a pessoa abre a proposta (`ProposalLive.Show`, `task_review`), clica em
"Revisar e criar a tarefa" (`/tasks?proposta=<id>`, `TaskLive.Index.handle_params/3`) e envia o
formulário (`handle_event("create")` → `Tasks.create_task/3`).

O que muda para quem usa:

1. **Pipeline no pedido.** O modal (`PipeMaestroWeb.ProposalRequest.request_modal/1`, `kind == "task"`)
   ganha um select de pipeline. A primeira opção, "Deixar o agente escolher" (valor vazio), é o padrão.
   Com um pipeline escolhido, o agente escreve a tarefa para ele, e a proposta usa esse pipeline mesmo
   que o agente sugira outro.
2. **Auto-aprovação.** O modal ganha o toggle "Criar e iniciar a tarefa sem revisão", ligado por
   padrão. Ligado: quando o job da proposta termina, o domínio cria a tarefa em nome de quem pediu. A
   tarefa é iniciada ou enfileirada (`start_or_queue`), sem ninguém com a página aberta. Se a criação
   não for possível, a proposta fica para revisão como hoje, e a tela diz por quê.
3. Proposta já transformada em tarefa: a tela mostra um link para a tarefa no lugar do botão de
   criar. Ninguém consegue criar uma segunda tarefa a partir dela.

Nada muda no avanço entre etapas (`Tasks.job_finished/1`, `Tasks.Engine`), na triagem por webhook
(`Proposals.triage_issue/4`) nem nas propostas de decisão, pipeline, análise ou melhoria.

### Critérios de aceite verificáveis

- O modal tem `data-testid="proposal-request-pipeline"` (select, "Deixar o agente escolher" com
  valor vazio por padrão) e `data-testid="proposal-request-auto-approve"` (switch/checkbox ligado
  por padrão), ambos feitos com componentes Petal.
- `TaskKind.changeset/2` rejeita um `pipeline_id` de outro workspace (ou que não existe).
- Com `pipeline_id` no input, `TaskKind.result/2` devolve esse pipeline em `pipeline` e em
  `task_params["pipeline_id"]`, mesmo que `output["pipeline"]` dê outro nome.
- Quando um job `task` com `auto_approve: true` termina e `pronta: true`, nasce uma tarefa
  `running` ou `queued`, ligada à proposta e registrada no `Audit`.
- `pronta: false`, nenhum pipeline resolvido, `auto_approve` desligado ou ausente (pedidos antigos),
  ou erro em `create_task`: nenhuma tarefa. Nos casos com auto-aprovação ligada, o motivo fica
  guardado e aparece em `data-testid="proposal-auto-approve-skipped"`.
- Terminar duas vezes ou criar manualmente depois não gera uma segunda tarefa.
- `ProposalLive.Show` troca `proposal-create-task` por `data-testid="proposal-created-task-link"`
  quando a tarefa existe, e se atualiza ao vivo quando ela nasce.
- `make ci` e `make e2e` verdes, com `make e2e.shots` claro e escuro auditados.

## Mudanças por app

### `apps/pipe_maestro` (domínio)

**`PipeMaestro.Proposals.TaskKind`** (`lib/pipe_maestro/proposals/task_kind.ex`)
- `@types`: acrescentar `pipeline_id: :binary_id` e `auto_approve: :boolean`.
- `changeset(attrs, workspace)`: passa a usar o `workspace`. Valida `pipeline_id` com
  `Pipelines.list_pipelines(workspace)`, ou um `get` por id e workspace, se já existir em
  `PipeMaestro.Pipelines`. A mensagem de erro é "não é um pipeline deste workspace". `auto_approve`
  não tem default no changeset: ausente vale `nil`, ou seja, desligado. Assim a triagem
  (`triage_issue`, que monta os attrs sem o campo) e os pedidos antigos seguem desligados. O padrão
  "ligado" vem do formulário (ver `ProposalRequest`).
- `stored_input/1` em `Proposals` já descarta `nil` e guarda o resto. `pipeline_id` e
  `auto_approve` entram no `input` sem mudança. Atenção: `false` não é `nil` e fica guardado, o que
  é o desejado.
- `job/3`: com `input[:pipeline_id]`, o prompt troca a seção "Os pipelines deste workspace" por
  "O pipeline desta tarefa: **Nome**: descrição (etapas)". Ele também instrui o agente a escrever
  para esse pipeline e a devolver o nome dele em `pipeline`. O `schema/0` continua igual.
- `result/2`: se `input["pipeline_id"]` resolver (no workspace do job), usa esse pipeline em
  `pipeline`, `pipeline_name` e `task_params["pipeline_id"]`. Se o pipeline escolhido tiver sido
  apagado depois do pedido, cai para a sugestão do agente, como hoje. Acrescentar ao resultado
  `auto_approve: input["auto_approve"] == true`, se a tela precisar dele.
- `@moduledoc`: descrever o pipeline escolhido e a auto-aprovação.

**`PipeMaestro.Proposals`** (`lib/pipe_maestro/proposals.ex`)
- Nova `job_finished(Job.t()) :: :ok`. Para `kind == "task"` com `input["auto_approve"] == true` e
  ainda sem tarefa criada:
  1. `result(job)`: com `{:error, msg}`, pula com o motivo `msg`;
  2. `ready == false`: pula com "O agente não considerou a tarefa pronta: …" mais as perguntas;
  3. `pipeline == nil`: pula com "Nenhum pipeline resolvido (o agente sugeriu "X")";
  4. `user = job.created_by_user`, que já vem pré-carregado por `Jobs.preload/1`, e o workspace por
     `job.workspace_id`;
  5. `create_task(user, workspace, job, result.task_params)` (abaixo). Em `{:error, changeset}`,
     pula com os erros do changeset em texto ("runner: não é um runner ativo…").
  - Em sucesso, grava `context["proposal"]["created_task_id"]` e
    `context["proposal"]["auto_approve"] = %{"status" => "created"}`, registra
    `Audit.record(workspace, user, "task.auto_created", task, %{"proposal_id" => job.id})` e notifica
    o job (abaixo).
  - Ao pular, grava `context["proposal"]["auto_approve"] = %{"status" => "skipped", "reason" => …}` e
    notifica. O motivo fica persistido porque um erro como "runner offline" não é recalculável depois.
  - Os demais kinds, ou `auto_approve` desligado: `:ok`, sem efeito.
- Nova `create_task(User.t(), Workspace.t(), Job.t(), map())`. É o **único** caminho para criar
  tarefa a partir de proposta, usado pela auto-aprovação e pelo formulário manual. Ela chama
  `Tasks.create_task/3` com `proposal_job_id` (ver idempotência) e, em sucesso, grava o
  `created_task_id` no contexto do job.
- Nova `created_task_id(Job.t()) :: Ecto.UUID.t() | nil` e `auto_approve(Job.t())`, que lê o
  status e o motivo, para a tela.
- `@moduledoc`: descrever o novo comportamento.

**Idempotência: a decisão de modelagem.** `Tasks.create_task/3` não pode rodar dentro de uma
transação externa com lock na linha do job. O comentário em `create_task` diz: "the first stage's
job is handed to the runner as it is created, so the task is committed first". O
`Jobs.create_stage_job/1` faz broadcast `{:job_assign, job}` logo depois do insert. Por isso, a
garantia fica no banco:
- **Migração** `apps/pipe_maestro/priv/repo/migrations/2026111…_add_proposal_job_to_tasks.exs`:
  `tasks.proposal_job_id` (`references(:jobs, type: :binary_id, on_delete: :nilify_all)`, nullable) e
  `unique_index(:tasks, [:proposal_job_id], where: "proposal_job_id IS NOT NULL")`.
- `PipeMaestro.Tasks.Task`: `belongs_to :proposal_job, Job`, no `@type` e no `@moduledoc`. **Não**
  entra no `cast` de `create_changeset/2`, para que um formulário não forje o vínculo. Ele é posto
  com `put_change` e `unique_constraint(:proposal_job_id, message: "esta proposta já virou uma tarefa")`.
- `PipeMaestro.Tasks.create_task/4`: a mesma função, com `opts \\ []` e `proposal: %Job{}`
  opcional, que faz o `put_change(:proposal_job_id, job.id)`. O `Repo.insert` sozinho já é atômico.
  Dois términos ou um clique manual concorrente resultam em uma única tarefa, e o segundo recebe
  `{:error, changeset}` com o erro de unicidade. `Proposals.create_task/4` também consulta o
  `created_task_id` antes de tentar, o caminho barato. O índice é o que garante.
- `context["proposal"]["created_task_id"]` é gravado depois do commit da tarefa, para a tela e os
  links. Se esse update falhar, a fonte de verdade continua sendo `tasks.proposal_job_id`.
  `created_task_id/1` pode cair para uma consulta `Tasks` por `proposal_job_id`.

**`PipeMaestro.Jobs`** (`lib/pipe_maestro/jobs.ex`)
- `finished/1` (por volta da linha 470): nova cláusula para
  `%Job{stage_run_id: nil, context: %{"proposal" => %{"kind" => "task"}}}` →
  `PipeMaestro.Proposals.job_finished(job)`. As cláusulas de análise e de etapa ficam como estão.
  `Proposals` já depende de `Jobs`, e `Jobs` já chama `PipeMaestro.Tasks` (que chama `Proposals`) por
  nome completo. Não há alias novo nem ciclo de compilação a mais. Conferir com
  `mix xref graph --format cycles` se o credo ou o compilador reclamarem.
- Nova `update_proposal(Job.t(), map()) :: Job.t()` (ou `merge_context/2`), pública e com `@spec`.
  Ela faz o merge no `context["proposal"]` sob `FOR UPDATE` e chama o `update!/2` privado, que já
  notifica `{:job_updated, job}` nos tópicos do job e do workspace. Assim, `ProposalLive.Show` recebe
  a segunda atualização com o `created_task_id` ou o motivo. Hoje `finish_job` notifica **antes** de
  `finished/1`, e essa ordem não muda.
- Só `finish_job/3` chama `finished/1`. Jobs que falham em `reconcile/2` ou são cancelados não
  passam por ele, e isso basta: só `:succeeded` pode gerar tarefa. Em qualquer outro status,
  `Proposals.result/1` devolve erro, e `job_finished` grava o motivo apenas se o job passou por
  `finish_job` com `auto_approve`.

**`PipeMaestro.Audit`**: só uma nova ação, `"task.auto_created"`. Se houver lista ou rótulo de ações
(conferir `lib/pipe_maestro/audit*.ex` e a tela de auditoria), acrescentar o texto "Tarefa criada
automaticamente da proposta". `Tasks.create_task` continua registrando `"task.created"`.

### `apps/pipe_maestro_web`

**`PipeMaestroWeb.ProposalRequest`** (`lib/pipe_maestro_web/proposal_request.ex`)
- `open/3`: para `kind == "task"`, os params padrão ganham `"auto_approve" => "true"` e carregam
  `pipelines: Pipelines.list_pipelines(workspace)` no mapa `t()`, com o `@type` atualizado.
- `request_modal/1`: para `kind == "task"`:
  - `<.icon_field type="select" field={@request.form[:pipeline_id]} icon="hero-arrows-right-left"
    label="Pipeline" prompt="Deixar o agente escolher" options={…} data-testid="proposal-request-pipeline" />`.
    O `prompt` do Petal gera a opção de valor vazio, e é ela que fica selecionada por padrão.
  - O toggle "Criar e iniciar a tarefa sem revisão" com `data-testid="proposal-request-auto-approve"`.
    Usar `<.field type="switch">` do Petal se a versão em `deps/petal_components` o declarar, o
    que **precisa ser conferido** na etapa de implementação. Se não declarar, usar
    `icon_field type="checkbox"` (`components/form_components.ex`), que já envolve
    `<.field type="checkbox">`. Os dois emitem o input hidden `false`, então desligar chega como
    `"false"`. Um texto de ajuda curto explica que a pessoa só é chamada se houver dúvida ou erro.
- `copy("task").intro`: deixar de dizer "Você revisa antes de criar" e explicar a auto-aprovação.
- `@moduledoc`: os novos campos.

**`PipeMaestroWeb.ProposalLive.Show`** (`lib/pipe_maestro_web/live/proposal_live/show.ex`)
- `assign_review(socket, "task")`: atribui `created_task_id` e `auto_approve` (status e motivo) a
  partir de `Proposals`.
- `task_review/1`:
  - com `created_task_id`, troca o botão `proposal-create-task` por
    `<.button link_type="live_redirect" to={task_link(...)} data-testid="proposal-created-task-link">Abrir a tarefa</.button>`;
  - com `auto_approve.status == "skipped"`, mostra
    `<.alert color="warning" data-testid="proposal-auto-approve-skipped">`, com "Não foi criada
    automaticamente: {motivo}", acima do botão de criar.
- `handle_info({:job_updated, job})` já reatribui o resultado (linha 131). Quando a atualização trouxer
  um `created_task_id` que antes não existia, e a proposta for de quem está olhando, fazer
  `push_navigate` para a tarefa com o flash "Tarefa criada e iniciada". O link também fica na página.
  Conferir se `{:job_updated}` substitui `@job` e chama `assign_result/1`. Se não, ajustar.
- `@moduledoc`: a tarefa criada sozinha.

**`PipeMaestroWeb.TaskLive.Index`** (`lib/pipe_maestro_web/live/task_live/index.ex`)
- `handle_params(%{"proposta" => id})`: se a proposta já tem tarefa, redireciona para ela com um
  flash, em vez de abrir o formulário. Caso contrário, guarda `proposal_job: job` no socket.
- `handle_event("create")`: com `proposal_job` presente, chama `Proposals.create_task/4`. Senão,
  `Tasks.create_task/3`. O erro de unicidade aparece no formulário, ou leva para a tarefa existente.
- `close_new`, `open_new` e `duplicate` limpam o `proposal_job`.

**Channels**: nenhuma mudança.

### `apps/pipe_maestro_protocol`
**Não muda.** `pipeline_id`, `auto_approve`, `created_task_id` e o status da auto-aprovação vivem em
`context["proposal"]`, chave do control plane que "never reaches the runner" (`Proposals` moduledoc).

### `apps/pipe_maestro_runner`
**Não muda.**

## Fronteiras

- O domínio continua sem web. A auto-aprovação mora em `Proposals.job_finished/1`, chamada por
  `Jobs.finished/1`, e funciona sem LiveView aberta.
- A web só chama contextos (`Proposals`, `Pipelines`, `Tasks`). As LiveViews continuam finas.
- O runner continua dependendo só de `protocol`. Nada aqui o toca.

## Protocolo

A mudança **não toca** `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels. O job
de proposta enviado ao runner (`PipeMaestroProtocol.Job`) tem o mesmo formato. Só o texto do prompt
muda quando há pipeline escolhido. `docs/specs/protocolo-runner.md` fica como está, a versão não
sobe e runners antigos seguem compatíveis.

## Telas

- **Modal "Escrever tarefa com IA"** (`ProposalRequest`, aberto em `TaskLive.Index`): select de
  pipeline (`proposal-request-pipeline`) e toggle (`proposal-request-auto-approve`). Petal: `.field`
  `type="select"` (via `icon_field`) e `type="switch"` ou `"checkbox"`, a conferir em
  `deps/petal_components` e em `docs/guias/ui-petal.md`. Nada de Tailwind cru para o toggle.
- **`ProposalLive.Show`** (revisão de tarefa): `proposal-created-task-link` (Petal `.button`) e
  `proposal-auto-approve-skipped` (Petal `.alert color="warning"`).
- **Playwright**: `e2e/tests/agent-proposals.spec.ts`:
  - o fluxo atual ("pede → revisa → cria") passa a **desligar** o toggle e mantém as asserções e os
    shots `task-proposal-review` e `task-proposal-form`;
  - novo fluxo com o toggle ligado (o padrão) e um pipeline escolhido: espera
    `proposal-created-task-link` (ou a navegação para a tarefa) e confere o pipeline da tarefa. O
    `fake_claude` do e2e precisa devolver `pronta: true`. Conferir `e2e/helpers` e o roteiro do
    fake runner para o kind task;
  - opcional: o aviso `proposal-auto-approve-skipped` com uma resposta `pronta: false`, se o fake
    permitir escolher a resposta;
  - `e2e/pages/ProposalPage.ts` (ou o page object usado): `submitRequest` aceita `pipeline` e
    `autoApprove`;
  - atualizar o `@flow` no cabeçalho do spec;
  - shots novos: `task-proposal-request` (já existe, agora com os campos novos),
    `task-proposal-auto-created` e `task-proposal-auto-skipped`, claro e escuro, via `make e2e.shots`.
- Conferir se `e2e/director` (a landing) usa o modal de tarefa. Se usar, o toggle ligado por padrão
  muda o roteiro e pode pedir ajuste.

## Testes

`apps/pipe_maestro/test/pipe_maestro/proposals_test.exs`:
- `TaskKind.changeset/2`: `pipeline_id` de outro workspace dá erro; do mesmo workspace, válido;
  `auto_approve` ausente fica `nil`.
- `TaskKind.job/3`: com `pipeline_id`, o prompt cita só o pipeline escolhido.
- `TaskKind.result/2`: com `pipeline_id`, ignora o nome sugerido pelo agente (`pipeline` e
  `task_params`).
- `Jobs.finish_job/3` de uma proposta `task` (runner de fixture com `scratch`, conectado e ativo):
  - `auto_approve` e `pronta: true` → `Repo.get_by(Task, proposal_job_id: job.id)` existe, com status
    `running` ou `queued` (testar os dois com `max_running_tasks`), `created_task_id` no contexto,
    `Audit` com `"task.auto_created"` e `created_by_user_id` de quem pediu;
  - `pronta: false` → nenhuma tarefa, `auto_approve.status == "skipped"` com motivo;
  - pipeline não resolvido (nome desconhecido, sem `pipeline_id`) → nenhuma tarefa, motivo;
  - `create_task` com erro (runner revogado ou diretório não anunciado) → nenhuma tarefa, motivo
    com o erro;
  - `auto_approve` desligado ou ausente → nenhuma tarefa, sem motivo gravado;
  - `Proposals.job_finished/1` chamado duas vezes → uma tarefa só;
  - `Proposals.create_task/4` manual depois da automática → `{:error, changeset}` com o erro de
    unicidade, e uma tarefa só.
- Em `tasks_test.exs`: `create_task/4` com `proposal:` grava `proposal_job_id`. O mesmo job duas
  vezes dá erro de unicidade.

`apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs`:
- o modal de tarefa mostra `proposal-request-pipeline` com "Deixar o agente escolher" e
  `proposal-request-auto-approve` marcado. Submeter guarda `auto_approve: true` e o `pipeline_id`
  no `input` do job;
- desmarcado, guarda `false`;
- `?proposta=<id>` de uma proposta que já tem tarefa redireciona para ela. Criar pelo formulário
  liga a tarefa à proposta.

`apps/pipe_maestro_web/test/pipe_maestro_web/live/proposal_live_test.exs`:
- proposta com `created_task_id` → `proposal-created-task-link`, sem `proposal-create-task`;
- proposta com `auto_approve.status == "skipped"` → `proposal-auto-approve-skipped` com o motivo;
- com a página aberta, terminar o job com auto-aprovação navega para a tarefa (`assert_redirect`)
  ou mostra o link.

Playwright: ver **Telas**.

## Documentação

- **ADR nova**: `docs/adr/0031-auto-aprovacao-da-tarefa-escrita-com-ia.md`. Registra a criação
  automática no fim do job e não na tela, o padrão ligado só no formulário (pedidos antigos e
  triagem desligados) e a idempotência por `tasks.proposal_job_id` com índice único, no lugar de um
  lock, porque `create_task` precisa commitar antes de entregar o job ao runner.
- Atualizar `docs/adr/0022-propostas-do-agente-como-mecanismo-geral.md`, só se ela disser que toda
  proposta passa por revisão humana. Nesse caso, uma linha "ver ADR 0031".
- `docs/specs/maquina-de-estados-tarefa.md`: mencionar que a tarefa pode nascer de uma proposta
  auto-aprovada. A máquina de estados não muda.
- Modelo de dados: se existir um spec ou uma tabela de colunas de `tasks` em `docs/specs/` ou
  `docs/plano/`, acrescentar `proposal_job_id`.
- `@moduledoc` de `TaskKind`, `Proposals`, `ProposalRequest`, `ProposalLive.Show` e `Tasks.Task`.
- `e2e/README.md`, se listar fluxos ou shots.

## Riscos

- **Migração**: só acrescenta uma coluna nullable e um índice parcial. Não afeta os dados que já
  existem. Propostas antigas não têm `auto_approve` e continuam como hoje.
- **Concorrência**: o término duplicado e o clique manual concorrente são resolvidos pelo índice
  único. O `update` do contexto do job usa `FOR UPDATE` para não pisar em outra escrita, como a de
  telemetria ou a de `add_increments`. A escrita do contexto acontece depois que a tarefa é
  commitada, de propósito.
- **Ordem das notificações**: `finish_job` notifica antes de `finished/1`. A tela vê primeiro o job
  terminado, sem tarefa, e logo depois a atualização com o link. Mostrar um estado "criando a
  tarefa…" seria possível, mas fica de fora. O resultado aparece em milissegundos.
- **`finish_job` no processo do Channel**: a criação da tarefa roda no processo do canal do runner,
  como `Tasks.job_finished/1` já faz hoje para etapas. Uma exceção em `create_task` derrubaria o
  canal, então `Proposals.job_finished/1` trata `{:error, _}` e nunca usa `!` nesse caminho.
- **Dialyzer**: `TaskKind.changeset/2` passa a usar o `workspace` (hoje `_workspace`). Os tipos de
  retorno novos (`create_task/4` e `job_finished/1 :: :ok`) precisam bater. O mapa `t()` de
  `ProposalRequest` ganha `pipelines`.
- **Cobertura**: os caminhos de pulo são cobertos pelos testes de domínio. Não é preciso excluir
  nada.
- **Credo**: `Jobs.finished/1` chama `PipeMaestro.Proposals` por nome completo, como já faz com
  `PipeMaestro.Tasks`. Se o `AliasUsage` reclamar, criar o alias.
- **e2e**: o padrão ligado muda o fluxo atual do spec, que precisa desligar o toggle. A landing
  (`e2e/director`) pode ser afetada se usar o modal de tarefa.
