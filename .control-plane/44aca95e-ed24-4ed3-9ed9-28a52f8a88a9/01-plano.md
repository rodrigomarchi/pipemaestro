# Plano: etapa que continua a sessão do agente da etapa anterior

Base: `origin/main` em `da4d4a0` (branch já em dia, sem commits alheios).

## Entendimento

Hoje cada etapa de uma tarefa roda o `claude` com contexto zerado:
`PipeMaestroRunner.Claude.argv/1` sempre passa `--no-session-persistence`
(ADR 0004). A tarefa cria, por etapa do pipeline, a escolha **Contexto**:

- `"fresh"` (padrão, comportamento atual): "Começar do zero";
- `"continue"`: "Continuar a etapa anterior". O agente retoma a sessão do CLI
  da etapa imediatamente anterior da mesma tarefa (`--resume <id> --fork-session`)
  e recebe o prompt desta etapa como próxima mensagem.

Para quem usa: no formulário do pipeline, um seletor por etapa; na tela da tarefa,
uma etapa que continuou a anterior diz isso de forma discreta, e diz quando caiu
para contexto zerado. Pipelines, tarefas e YAMLs existentes continuam `"fresh"`.

Nomes adotados (consistentes em domínio, YAML, protocolo e tela):
`Stage.context` (`"fresh" | "continue"`), `Job.persist_session`,
`Job.resume_session_id`, capacidade `"resume_session"`, e `session_resumed`
no `job:finished` e em `PipeMaestro.Jobs.Job`.

### Critérios de aceite verificáveis
1. Changeset do pipeline aceita `"continue"` numa etapa comum e recusa, com erro
   em português no campo `context` da etapa: (a) primeira etapa; (b) etapa com
   `group`; (c) etapa cuja anterior tem `group`.
2. `Tasks`: o job da etapa N leva `persist_session: true` quando a N+1 é
   `"continue"`; o job de uma etapa `"continue"` leva `resume_session_id` = o
   `session_id` do job da última tentativa **que passou** da etapa anterior,
   inclusive numa 2ª tentativa; runner sem `"resume_session"` → nenhum dos dois
   campos; etapa anterior sem `session_id` → sem `resume_session_id`.
3. Protocolo: ida e volta `to_map`/`from_map` com os campos novos; valores
   inválidos recusados; `Hello.capabilities/0` inclui `"resume_session"`.
4. Runner (CLI falso): `argv` com `--resume <id> --fork-session` e sem
   `--no-session-persistence` quando deve; falha ao retomar → uma nova execução
   sem `--resume`, `job:finished` com `session_resumed: false`, etapa não trava.
5. YAML: ida e volta com o campo passa para todos os templates; YAML sem o campo
   → `"fresh"`.
6. e2e do formulário: seletor + erro na primeira etapa; `make e2e.shots` claro/escuro.
7. ADR 0041 criado; ADR 0004 aponta para ele.
8. `make ci` e `make e2e` verdes.

## Mudanças por app

### `apps/pipe_maestro` (domínio)

- **`PipeMaestro.Pipelines.Stage`** (`pipelines/stage.ex`): `field :context, :string,
  default: "fresh"`; `@contexts ~w(fresh continue)` com `contexts/0` (`@spec`);
  `cast` + `validate_inclusion(:context, @contexts, message: "escolha como a etapa começa")`;
  `@type t` e `@moduledoc` atualizados. Um `nil` vindo de formulário/YAML vira `"fresh"`.
  Como é campo de embed (JSONB em `pipelines.stages` e `tasks.stages`), **não há
  migração para a etapa**: documentos antigos sem a chave carregam o default `"fresh"`.
- **`PipeMaestro.Pipelines.Pipeline.validate_stages/1`** (`pipelines/pipeline.ex`):
  nova validação vizinha. Como o erro deve aparecer **no campo da etapa**, ela
  percorre os changesets do embed (`get_change(changeset, :stages)` /
  `Ecto.Changeset.get_embed`), adiciona o erro em `:context` do changeset da etapa
  i e recoloca a lista com `put_embed` (padrão Ecto para erros em embeds), marcando
  o pipeline inválido. Mensagens:
  - 1ª etapa: "a primeira etapa não tem uma etapa anterior para continuar";
  - etapa em grupo: "uma etapa em paralelo não pode continuar a anterior";
  - anterior em grupo: "a etapa anterior roda em paralelo: não há uma sessão só para continuar".
- **`PipeMaestro.Pipelines.Yaml`** (`pipelines/yaml.ex`): exportar `{"context", stage.context}`
  só quando `"continue"` (omitir `"fresh"` mantém os YAMLs exportados iguais aos de
  hoje e o teste de ida e volta estável); importar com `"context"` no `Map.take`
  de `stage_attrs/1`. Sem a chave → default `"fresh"`.
- **`PipeMaestro.Pipelines.Json`** (`pipelines/json.ex`, propostas do agente): conferir
  se descreve/aceita as chaves da etapa; se sim, incluir `context` (opcional).
- **`PipeMaestro.Tasks`** (`tasks.ex`):
  - `job_context/3` (privado, ~linha 516) ganha
    `"persist_session" => if(resumable? and next_continues?(task, index), do: true)` e
    `"resume_session_id" => if(resumable? and stage.context == "continue", do: previous_session_id(task, index))`,
    onde `resumable? = Runners.capable?(runner, "resume_session")` com o runner da
    tarefa (`task.runner_id`; carregado uma vez, seguindo `PipeMaestro.Proposals.capable?/1`).
  - `previous_session_id/2`: `StageRun` da tarefa com `index == index - 1`,
    `status == :passed`, `order_by desc: attempt`, `limit 1`, `preload :job` →
    `job.session_id` (ou `nil`). Não depende da tentativa atual, então a 2ª tentativa
    retoma a etapa anterior; o retorno da falha segue por `previous_feedback/2`.
  - `next_continues?/2`: `Enum.at(task.stages, index + 1)` com `context == "continue"`.
  - A etapa de correção (`correction_stage/1`) continua `"fresh"` (fora do escopo).
- **`PipeMaestro.Jobs.Job`** (`jobs/job.ex`): `field :session_resumed, :boolean`
  no cast de fim de job (lista ~linha 225), `@type`, `@moduledoc`. **Migração** nova
  em `apps/pipe_maestro/priv/repo/migrations/` adicionando `session_resumed boolean`
  (nulo) a `jobs`. Nulo = não pediu retomada (ou runner antigo).
- **`PipeMaestro.Jobs`**: confirmar que o caminho do `job:finished` repassa
  `session_resumed` ao changeset (mesmo caminho de `session_id`).
- Templates (`pipelines/templates.ex`): **não mudam** (fora do escopo).

### `apps/pipe_maestro_web`

- **`PipelineLive.FormFields`** (`live/pipeline_live/form_fields.ex`): no bloco
  "Avançado" (junto de `agent` e `group`), `<.icon_field type="select" field={@stage[:context]}
  icon="hero-arrow-uturn-right" label="Contexto" options={[{"Começar do zero", "fresh"},
  {"Continuar a etapa anterior", "continue"}]} help_text="..." data-testid={"stage-context-#{@stage.index}"} />`
  (padrão `icon_field` de `docs/guias/ui-petal.md`, já usado com `type="select"` em
  `usage_live.ex`). O `<.field>` do Petal mostra os erros do campo. O resumo do
  `<summary>` passa a mencionar o contexto. Como o erro pode ficar escondido no
  `<details>` fechado, abrir o `details` quando a etapa tiver erro em `context`.
- **`PipelineLive.StageParams`** (`stage_params.ex`): incluir `"context"` onde as
  chaves da etapa são listadas/normalizadas (adicionar/remover/reordenar etapas).
- **Tela da tarefa** (`components/task_components.ex`, `live/task_live/show.ex`): na
  linha da tentativa (`stage_run_status/1` ou vizinho), um selo discreto
  `data-testid={"stage-run-session-#{id}"}`: "Continuou a etapa anterior" quando
  `job.context["resume_session_id"]` e `session_resumed != false`; "Começou do zero:
  a sessão anterior não estava disponível" quando `session_resumed == false`.
  Em `components/audit_components.ex`, junto de "Sessão do CLI", um `fact`
  "Retomou a sessão" com o id retomado.
- **Channels** (`channels/runner_channel.ex`): **não muda**. `push_assign/2` já
  repassa `job.context` inteiro por `Job.new/1`; o `job:finished` segue o caminho atual.

### `apps/pipe_maestro_protocol`

- **`PipeMaestroProtocol.Job`**: `persist_session` (booleano) e `resume_session_id`
  (texto 1..100 bytes, `~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/`: UUIDs do CLI, sem
  espaço nem `/`) em `defstruct`, `@type t`, `@optional` e `check/2`. `consistent/1`
  recusa `resume_session_id` com `scratch: true`. `@moduledoc` descreve os dois
  campos e `session_resumed` no `job:finished`.
- **`PipeMaestroProtocol.Hello`**: `capabilities/0` inclui `"resume_session"`; moduledoc.

### `apps/pipe_maestro_runner`

- **`PipeMaestroRunner.Claude.argv/1`**: `--no-session-persistence` só quando nem
  `persist_session` nem `resume_session_id`; com `resume_session_id`,
  `["--resume", id, "--fork-session"]`. `@moduledoc` atualizado.
- **`PipeMaestroRunner.JobRunner`**:
  - no estado do run, `resume: :none | :requested | :fell_back`;
  - em `after_exit/3`: se o job tem `resume_session_id`, o código ≠ 0, não foi
    cancelado nem estourou o tempo e **nenhuma linha `system` (init) chegou**
    (`current.session == nil`, ou seja, o CLI morreu antes de abrir sessão), relança
    **uma vez** o mesmo job com `resume_session_id: nil` (mantendo `persist_session`)
    no mesmo `dir`, sem refazer setup nem reanexar `notes` ao prompt; zera
    `stderr`/`seq` não, (os eventos seguem numerados), e marca `:fell_back`.
    Para isso, guardar `path` do executável no run em `launch/3`.
  - em `audit/2`/`finish/4`: `"session_resumed" => true | false` só quando o job pediu
    retomada; com `:fell_back`, `false`.
  - O timeout do job continua valendo (o `{:timeout, id, port}` é por porta; a nova
    porta agenda o seu, limitado ao restante).
- **CLI falso** (`test/support/fake_claude`): com `--resume <id>` cujo id começa com
  `ausente`, escreve "No conversation found with session ID: <id>" no stderr e sai 1
  sem linha alguma; e, com `$FAKE_CLAUDE_ARGS_FILE`, grava o argv (para os testes
  conferirem `--fork-session` e a ausência de `--no-session-persistence`).
- Arquivos de sessão: o CLI grava em `~/.claude/projects/<cwd codificado>/`. O cwd de
  uma etapa de tarefa é `<workdir>/worktrees/<task_id>` (`Workspace`), estável entre
  etapas e tentativas, então o `--resume` acha a sessão. Limpeza ao remover o
  worktree: **fora do escopo**, registrada como pendência no ADR (apagar só os
  `.jsonl` desse cwd seria possível, mas mexe num diretório do CLI que não é nosso).

## Fronteiras

- Runner continua dependendo só de `protocol` (só usa `PipeMaestroProtocol.Job`).
- Domínio não ganha nada de web; a web só lê `Stage.context`, `Job.session_resumed`
  e `job.context`. Nenhuma dependência nova.

## Protocolo

- **Toca** `apps/pipe_maestro_protocol` e o formato das mensagens: dois campos
  opcionais em `job:assign`, um em `job:finished`, uma capacidade nova no hello.
- **Versão não sobe** (`protocol_version` 4): a mudança é aditiva, como
  `"scratch"` e `"git_credential"` (§5 da spec: sobe só o que quebra compatibilidade).
- **Runner antigo: degradado, nunca recusado.** O control plane só põe
  `persist_session`/`resume_session_id` no job se o runner anunciou
  `"resume_session"`; um runner sem ela roda a etapa com contexto zerado. Mesmo que
  o job chegue com os campos (capacidade gravada desatualizada), `Job.new/1` de um
  runner antigo só lê as chaves de `@optional` e ignora as desconhecidas: roda do
  zero. O `job:finished` de um runner antigo não tem `session_resumed` → a tela não
  mostra selo (o job nem pediu retomada nesse caso).
- `docs/specs/protocolo-runner.md`: linhas de `persist_session` e
  `resume_session_id` na tabela de campos do job (§ campos do `job:assign`),
  `session_resumed` no `job:finished` (§ auditoria), e `"resume_session"` na lista
  de `capabilities` do hello.

## Telas

- Formulário do pipeline (`PipelineLive` new/edit): seletor
  `stage-context-<index>`; erro exibido pelo próprio campo.
- Tela da tarefa: selo `stage-run-session-<id>` na tentativa.
- Componentes: `<.icon_field type="select">` (Petal `<.field>` por baixo), `<.badge>`
  do Petal para o selo (conferir attrs no pacote, como pede `ui-petal.md`).
- Playwright: novo teste em `e2e/tests/pipeline-diagram.spec.ts` ou novo
  `e2e/tests/pipeline-stage-context.spec.ts`: escolher "Continuar a etapa anterior"
  na etapa 0 → salvar → ver o erro; na etapa 1 → salvar com sucesso e reabrir
  mostrando a escolha. `make e2e.shots` claro/escuro do formulário (com o erro).
  O selo na tela da tarefa é coberto por teste de LiveView (o e2e de tarefa com
  runner real só cobre se o CLI falso suportar; opcional em `task-pipeline.spec.ts`).

## Testes

- `apps/pipe_maestro/test/pipe_maestro/pipelines_test.exs` (ou `pipelines/`):
  `"continue"` aceito; recusado nos 3 casos, erro no `context` da etapa; default `"fresh"`.
- YAML (teste de ida e volta existente) + caso explícito com `context: continue` e
  um YAML sem o campo → `"fresh"`.
- `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs`: pipeline de 3 etapas
  (fresh, continue, fresh) com runner da fixture com `"resume_session"`
  (`test/support/fixtures.ex` ~linha 222 ganha a capacidade); job 1 com
  `persist_session`, job 2 com `resume_session_id` = `session_id` do job 1; job 2
  falha → 2ª tentativa ainda com o `session_id` do job 1; runner sem a capacidade →
  sem campos; job 1 sem `session_id` → sem `resume_session_id`.
- `apps/pipe_maestro/test/pipe_maestro/jobs_test.exs`: `session_resumed` gravado no fim.
- Protocolo: `job_test.exs` (ida e volta, booleano inválido, id inválido, `scratch`
  com resume), `hello_test.exs` (capacidade).
- Runner: `claude_test.exs` (argv nos 3 casos) e `job_runner_test.exs` com o CLI
  falso (argv gravado; `ausente-…` cai para contexto zerado, `job:finished`
  `succeeded` com `session_resumed: false`; cancelamento durante a retomada não relança).
- Web: teste do `PipelineLive` (seletor renderizado, erro na 1ª etapa) e do
  componente da tarefa (selo nos dois estados).

## Documentação

- **ADR 0041** `docs/adr/0041-continuar-a-sessao-da-etapa-anterior.md`: a decisão,
  por que `--fork-session` (a sessão da etapa anterior fica intacta para novas
  tentativas e cada job tem seu `session_id`), as restrições (só a anterior
  imediata, sem grupos, mesmo runner/worktree), a degradação para contexto zerado
  e a pendência de limpar as sessões do CLI.
- **ADR 0004**: o trecho sobre `--no-session-persistence` passa a apontar para a 0041.
- `docs/specs/protocolo-runner.md` como descrito em Protocolo.
- `@moduledoc` de `Stage`, `Job` (protocolo e domínio), `Hello`, `Claude`.

## Riscos

- **Migração**: só uma coluna nula em `jobs`; sem backfill. Embeds sem a chave
  carregam o default.
- **Erros em embeds**: adicionar erro ao changeset da etapa dentro do changeset do
  pipeline exige `put_embed` com os changesets alterados; cuidar para não perder
  as mudanças já castadas (testar formulário com várias etapas).
- **Detecção da falha ao retomar**: depende de o CLI morrer antes da linha `system`.
  Se uma versão do CLI emitir o init antes de falhar, a heurística não relança;
  a etapa então falha normalmente e a nova tentativa segue o fluxo atual (não
  trava). Documentar no ADR.
- **Sessões crescem**: retomar carrega todo o histórico (custo de cache/contexto);
  compactação é fora do escopo. Persistir sessões grava transcrições em
  `~/.claude/projects` na máquina do runner (antes não gravava): registrar no ADR.
- **Concorrência**: etapas `"continue"` nunca são paralelas (validação), e
  `--fork-session` evita que duas tentativas escrevam na mesma sessão.
- **Mudança de runner da tarefa** (`reopen/2` com outro `runner_id`): o
  `session_id` não existe na outra máquina → cai para contexto zerado (coberto pelo
  item 10).
- **Cobertura/dialyzer**: novos campos com `@type`/`@spec`; `resume` no estado do
  runner tipado; o relançamento precisa de teste para não baixar a cobertura do runner.
