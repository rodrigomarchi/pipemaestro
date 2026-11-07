# Plano: arquivos gerados no runner como anexos da etapa

Base: `origin/main` em `da4d4a0` (a branch já estava em dia, sem commits de outras tarefas).

Lido: `docs/plano/01-visao-arquitetura.md`, `docs/specs/protocolo-runner.md`, ADR 0033 e
ADR 0039, `PipeMaestroProtocol.{Hello, Job}`, `PipeMaestroRunner.{JobRunner, Claude,
Workspace, Connection}`, `PipeMaestro.{Jobs, Runners, Tasks, Tasks.Contract,
Pipelines.Prompt}`, `PipeMaestroWeb.{Router, Endpoint, CacheBodyReader, UserAuth,
TaskLive.Show}`, `docs/guias/ui-petal.md`, `docs/guias/instalacao.md`,
`docs/guias/deploy.md`, `e2e/README.md`, `e2e/tests/task-pipeline.spec.ts` e
`apps/pipe_maestro_runner/test/support/fake_claude`.

## Entendimento

Hoje só o artefato Markdown da etapa (até 64 KB, `JobRunner.read_artifact/1` →
`"artifact"` do `job:finished` → `stage_runs.artifact`) chega à plataforma. O que o
agente gera no runner, como as screenshots do `make e2e.shots`, um CSV ou um relatório,
some com o worktree.

Com a mudança:

- cada job do runner ganha uma pasta própria fora de qualquer worktree, em
  `<workdir>/files/<job_id>/`, passada ao agente em `CP_FILES_DIR`;
- quando o agente termina e antes do `job:finished`, o runner sobe por HTTP cada arquivo
  regular dessa pasta;
- a plataforma guarda os arquivos no Postgres, ligados ao job e ao stage run;
- a página da tarefa mostra as imagens em miniatura e os outros arquivos com link de
  download, por tentativa e numa aba com todos os arquivos da tarefa.

### Critérios de aceite (verificáveis)

1. Um agente que copia `a.png` e `dados/r.csv` para `$CP_FILES_DIR` termina com os dois em
   `job_files`, ligados ao job e ao stage run, com `content_type` (`image/png`,
   `text/csv`), `byte_size` e `sha256` corretos. Há um teste do `JobRunner` com o
   `fake_claude` e um teste de controller.
2. Reenviar `(job_id, path)` substitui o arquivo, sem duplicar.
3. O endpoint responde 401 (token inválido), 404 (job de outro runner), 413 (acima de um
   limite) e 422 (caminho com `..` ou absoluto). Cada caso tem teste.
4. Um runner sem a capacidade `files` funciona como hoje, e o prompt dele não cita
   `CP_FILES_DIR`. Um control plane antigo (o endpoint dá 404) não quebra o runner novo:
   o job termina com o status que teria e `files_failed` vai no `job:finished`.
5. Nada de `$CP_FILES_DIR` entra no git do worktree, e `clean`/`artifact_committed` não
   mudam.
6. Na página da tarefa, a imagem aparece em miniatura e abre, e o CSV baixa com
   `Content-Disposition: attachment`. Um usuário de outro workspace recebe 404.
7. Há um spec Playwright novo, `make e2e` passa e `make e2e.shots` foi conferido em claro
   e escuro.
8. Há uma ADR nova, e `docs/specs/protocolo-runner.md` está atualizado.
9. `make ci` passa.

## Protocolo

**Toca `apps/pipe_maestro_protocol` e o formato das mensagens, de forma aditiva. A
`protocol_version` continua 4.** É o padrão da ADR 0039: capacidade no `Hello`, campo
opcional novo e mensagem nova fora do canal.

| O que | Mudança |
|---|---|
| `Hello.capabilities/0` | ganha `"files"` |
| `Job` `@reserved_env` | ganha `CP_FILES_DIR`, para que um segredo do workspace não a sobrescreva |
| `job:finished` | ganha o campo opcional `"files_failed"` (inteiro ≥ 0, só quando > 0) |
| HTTP novo | `PUT /api/runner/jobs/:job_id/files?path=<relativo>`, fora do canal |

O que os dois lados precisam combinar vai num módulo novo,
`PipeMaestroProtocol.JobFiles`:

- `capability/0` (`"files"`) e `env/0` (`"CP_FILES_DIR"`);
- `path/1` (`"/api/runner/jobs/<id>/files"`);
- `@max_file_bytes 10_485_760`, `@max_job_bytes 52_428_800` e `@max_files 100`, com uma
  função pública para cada um;
- `valid_path?/1`: relativo, sem `..`, `.`, `\`, NUL nem segmento vazio, e até 255
  bytes.

O `@moduledoc` de `Hello` e de `Job` passa a citar a capacidade, a env e
`files_failed`.

**Runner antigo** (sem `"files"`) é **compatível**:

- não é recusado nem degradado;
- o control plane não cita `CP_FILES_DIR` no prompt dos jobs dele;
- o endpoint nunca é chamado, e a tela não mostra a seção "Arquivos";
- na prática, o control plane exige a versão de runner do deploy (ADR 0023/0035), então
  os runners se atualizam juntos. Mesmo assim, o caminho antigo continua correto.

**Control plane antigo com runner novo:**

- a capacidade desconhecida passa pela validação do `Hello` (palavras livres);
- o `PUT` recebe 404, e o runner não repete um 4xx. Ele conta o arquivo em
  `files_failed`, e o job termina normalmente;
- o `cast` do `finish_changeset` antigo ignora a chave desconhecida.

Na implementação, confirme que `RunnerChannel.handle_in("job:finished", …)` não rejeita
chaves extras.

`docs/specs/protocolo-runner.md` ganha:

- `files` na lista de capacidades (§3);
- `CP_FILES_DIR` ao lado de `artifact_path` (§4.4), dizendo que vale para qualquer job;
- `files_failed` no `job:finished` (§4.2);
- uma seção nova, §4.8 "Arquivos do job", com o endpoint, a autenticação, os limites,
  as respostas e as tentativas.

## Fronteiras

- O runner continua dependendo só de `protocol`. O upload usa o `Req`, que ele já tem, e
  os testes usam `Bandit`/`Plug`, que já estão nas deps (como em `forgejo_server.exs`).
- O domínio não ganha nada de web. Ele recebe `(runner, job_id, path, binary)` já lido, e
  a leitura do corpo HTTP fica no controller.
- O `content_type` vem de `MIME.from_path/1` no domínio. `:mime` já está no `mix.lock`
  (via `req`/`plug`), mas `apps/pipe_maestro/mix.exs` precisa declará-lo
  (`{:mime, "~> 2.0"}`). Sem isso, o compilador avisa que o app usa um módulo de uma
  dependência não declarada.

## Mudanças por app

### `apps/pipe_maestro_protocol`

- **Novo:** `lib/pipe_maestro_protocol/job_files.ex` (acima), com `@spec` e
  `@moduledoc`.
- `hello.ex`: `capabilities/0` ganha `"files"`, e o moduledoc a cita.
- `job.ex`: `@reserved_env` ganha `CP_FILES_DIR`. O moduledoc ganha `files_failed` no
  `job:finished` e a env.
- Testes: `job_files_test.exs` (`valid_path?/1` com `..`, absoluto, `./`, `\`, NUL,
  vazio, longo e subpasta válida), `hello_test` e o teste de env reservada em
  `job_test`.

### `apps/pipe_maestro_runner`

- **Novo `PipeMaestroRunner.JobFiles`:**
  - `dir(workdir, job_id)` → `<workdir>/files/<job_id>`;
  - `prepare/2`: `mkdir_p`;
  - `clear/1`: apaga `<workdir>/files` no `init`, como `Workspace.clear_scratch/1`;
  - `collect(dir, secrets)`:
    - percorre a pasta recursivamente com `File.lstat`;
    - ignora symlinks e tudo o que não é arquivo regular;
    - devolve, em ordem de caminho, os que passam em `valid_path?/1`, nos limites por
      arquivo, total e quantidade, e cujo caminho não contém o valor de nenhum segredo de
      `env`;
    - registra no log os que pula. O caminho é redigido pelo `LogCollector`, que ainda
      conhece os segredos do job nessa hora, e um caminho com segredo aparece como
      `[redigido]`;
  - `upload(files, url, token, job_id, req_options)`:
    - `Req.put` com `Authorization: Bearer`, `Content-Type: application/octet-stream`,
      `params: [path: …]` e o corpo lido do disco;
    - tenta de novo em erro de rede e 5xx (3 tentativas, backoff de 0,5 s, 1 s e 2 s);
    - não repete um 4xx;
    - devolve `%{uploaded, failed}`.
- `claude.ex` (`Claude.env/2`): passa `CP_FILES_DIR` com o caminho absoluto. Um job sem
  a pasta (JobRunner sem upload configurado) tira a env, como faz com
  `CP_ARTIFACT_PATH`. O moduledoc é atualizado.
- `job_runner.ex`:
  - opção nova `:files`, `%{url, token}` ou `nil`, e `:files_req_options` para os
    testes;
  - no preparo do job, cria a pasta;
  - depois do agente, o upload roda **fora do processo do GenServer**. `after_exit/3`
    passa a ir pelo `Task` de `after_agent/4` também quando há upload, que vem por
    último (depois dos checks, gates, entrega e `changes`);
  - o upload vale para jobs `succeeded`, `failed` e `canceled`: a screenshot de um e2e
    que falhou também interessa;
  - `finish/4` põe `"files_failed"` quando for > 0. Esse número soma os pulados por
    limite ou por nome e os que falharam no envio. É o "quantos não subiram" da tela, e o
    log do runner diz o motivo de cada um;
  - depois do `out(job:finished)`, apaga a pasta em background, como em
    `discard_scratch/2`.
- `connection.ex`: `start_job_runner/1` passa `files: %{url: config.url, token:
  config.token}` ao `JobRunner`.
- `test/support/fake_claude`: modo novo `[arquivos]`. Ele grava em `$CP_FILES_DIR` um PNG
  1×1 (com `printf` em octal, sem depender do `base64`), `a.png`, e `dados/r.csv`, e cria
  um symlink, que deve ser ignorado.
- **Novo** `test/support/files_server.exs`, um Bandit que grava os `PUT`
  (`Authorization`, `path`, corpo) e pode responder 404 ou 500.

### `apps/pipe_maestro` (domínio)

- **Migração** `20261116090000_create_job_files.exs`, depois da última
  (`20261115120000_…`):
  - tabela `job_files` com `id` uuid;
  - `workspace_id` (fk `delete_all`), `job_id` (fk `delete_all`, não nulo) e
    `stage_run_id` (fk `delete_all`, nulo);
  - `path` (text), `content_type`, `byte_size` (bigint), `sha256` (string, hex),
    `content` (`:binary` → `bytea`) e timestamps;
  - `unique_index [:job_id, :path]`, e índices em `stage_run_id` e `workspace_id`.

  Na mesma migração: `alter table(:jobs) add :files_failed, :integer`.
- **Schema `PipeMaestro.Jobs.JobFile`.** `File` colidiria com o módulo do Elixir. O campo
  `content` usa `load_in_query: false`, para que nenhuma listagem o carregue, e o
  download o pede com `select`.
- **Contexto `PipeMaestro.Jobs.Files`**, todo com `@spec`:
  - `store(runner, job_id, path, content)` →
    `{:ok, JobFile.t()} | {:error, :not_found | :invalid_path | :too_large}`:
    - o job precisa ser desse runner (`fetch_for_runner`), e outro runner recebe
      `:not_found`;
    - valida o caminho com `PipeMaestroProtocol.JobFiles.valid_path?/1`;
    - numa transação com `FOR UPDATE` na linha do job, confere a quantidade e a soma do
      job, sem contar o arquivo que será substituído;
    - calcula `byte_size`, `sha256` (`:crypto`) e `content_type`
      (`MIME.from_path/1`);
    - faz upsert com `on_conflict: {:replace, [content, content_type, byte_size, sha256,
      updated_at]}` e `conflict_target: [:job_id, :path]`;
    - copia `workspace_id` e `stage_run_id` do job.
  - `list_for_stage_run(stage_run)`, sem `content`, por `path`.
  - `list_for_task(task)` → `%{stage_run_id => [JobFile]}`, numa query só.
  - `get_for_download(workspace, id)`: o arquivo com `content`, ou `nil` quando não é do
    workspace.
  - `image?/1`: `png`, `jpg`, `jpeg`, `gif` e `webp`, pelo `content_type` guardado.
  - `limits/0`, que lê do protocolo.

  Por enquanto, o `Jobs` só aponta para o `Files` no moduledoc.
- `Jobs.Job`: campo `files_failed` e `cast` em `finish_changeset/3`.
- `Pipelines.Prompt.build/2`: `context[:files]` (booleano). Quando verdadeiro, o
  cabeçalho fixo ganha uma linha:

  > - Arquivos que a pessoa deve ver na plataforma (screenshots, relatórios, CSVs) devem
  >   ser **copiados** para `$CP_FILES_DIR` (pode usar subpastas). Essa pasta fica fora do
  >   git, e a plataforma os mostra na tarefa.

  A linha vai no cabeçalho de toda etapa, e não em `Tasks.Contract.prompt/1`, que só
  existe em etapas que entregam. Assim vale para qualquer pipeline.
- `Tasks.start_stage/5`: calcula
  `files: Runners.capable?(runner, PipeMaestroProtocol.JobFiles.capability())` com o
  runner da tarefa, carregado se não vier pré-carregado. Ele usa as capacidades do
  último `Hello`, como `Proposals.capable?/1`.
- `Tasks`, `StageRun` e `Contract` não mudam. Os checks seguem iguais, porque a pasta
  fica fora do worktree.

### `apps/pipe_maestro_web`

- **Upload:** `PipeMaestroWeb.RunnerFileController.create/2`, rota
  `put "/api/runner/jobs/:job_id/files"` no scope `:api`.
  - Autenticação: `Authorization: Bearer cpr_…` → `Runners.authenticate_runner/1`. Sem
    token, ou com um token inválido ou revogado, responde 401.
  - Exige `Content-Type: application/octet-stream`, e responde 415 a qualquer outro.
    O `Plug.Parsers` do endpoint tem `pass: ["*/*"]`, então não lê esse corpo. O
    `CacheBodyReader` só entra quando um parser lê, então não duplica nada.
  - Recusa logo pelo `Content-Length`, se ele vier, acima do limite. Depois lê com
    `Plug.Conn.read_body/2` em laço (`length` de 1 MB por leitura) e para com 413 ao
    passar de `max_file_bytes`.
  - Respostas:
    - 201 `{"path", "byte_size", "sha256", "content_type"}`;
    - 404 `{"error": "not_found"}` para um job inexistente ou de outro runner, sem dizer
      qual dos dois;
    - 413 `{"error": "too_large", "limit"}`;
    - 422 `{"error": "invalid_path"}`.
  - Nunca registra o corpo nem o caminho em log.
- **Download:** `PipeMaestroWeb.JobFileController.show/2`, rota
  `get "/w/:workspace_slug/files/:id"` no scope
  `[:browser, :require_authenticated_user]`.
  - Resolve o workspace por `Workspaces.get_workspace_for_user/2` e o arquivo por
    `Files.get_for_download/2`. Se um dos dois não existir, responde 404.
  - Cabeçalhos:
    - `x-content-type-options: nosniff`;
    - `content-type` guardado;
    - `content-disposition: inline; filename*=UTF-8''<nome>` só para as imagens raster;
      todo o resto, SVG e HTML incluídos, vai como `attachment`;
    - `content-security-policy: sandbox; default-src 'none'`, como defesa extra;
    - `cache-control: private, max-age=3600`.
- **Componente novo** `PipeMaestroWeb.JobFileComponents.files/1`:
  - grade de miniaturas (`<img loading="lazy">` dentro de um link para o download em
    nova aba, que abre em tamanho real);
  - lista dos outros arquivos com ícone, nome, tamanho e link de download (Petal
    `<.link>`/`<.icon>`/`<.badge>`);
  - aviso (Petal `<.alert color="warning">`) quando `files_failed > 0`.
- **`TaskLive.Show`**, uma LiveView fina:
  - carrega `Files.list_for_task/1` no mount e a cada `{:task_updated, _}`. Os arquivos
    chegam antes do `job:finished`, que gera o `task_updated`;
  - `attempt/1` ganha a seção **"Arquivos"** junto do artefato, com os arquivos daquela
    tentativa e o aviso de `run.job.files_failed`;
  - uma aba nova **"Anexos"** (`?aba=anexos`, com contador) agrupa todos os arquivos da
    tarefa por etapa e tentativa, das mais recentes para as mais antigas. A tela já é
    toda em abas (`docs/guias/ui-petal.md`, "Telas em abas"), e a aba "Arquivos" que já
    existe lista os arquivos **alterados no git**. Por isso a aba nova se chama
    "Anexos", para não misturar os dois assuntos.
- `JobLive` (a página do job avulso) **não muda** nesta tarefa. Os arquivos de jobs sem
  tarefa ficam guardados, e mostrá-los lá é um passo seguinte com o mesmo componente.

#### `data-testid`

A chave natural é `<stage.key>-<attempt>-<path>`, e o `path` vai como está, com `/`.

- Por tentativa:
  - `stage-run-files-<key>-<attempt>` (a seção);
  - `stage-run-file-<key>-<attempt>-<path>` (o item);
  - `stage-run-file-thumb-<key>-<attempt>-<path>` (a miniatura);
  - `stage-run-file-download-<key>-<attempt>-<path>`;
  - `stage-run-files-failed-<key>-<attempt>`.
- Na aba: `task-tab-anexos`, `task-tab-count-anexos`, `task-panel-anexos`,
  `task-attachments-<key>-<attempt>` e `task-no-attachments`.

## Testes por critério

| Critério | Teste |
|---|---|
| 1 | `job_runner_test`: o `fake_claude` em `[arquivos]` contra o `files_server`, que recebe `a.png` e `dados/r.csv` com o Bearer certo e sem o symlink, e a pasta some depois. `runner_file_controller_test`: o upload grava `content_type`, `byte_size` e `sha256` e liga ao `stage_run_id`. `files_test` (domínio): `store/4` e as listagens sem `content` |
| 2 | `files_test` e o controller: dois `PUT` no mesmo caminho deixam uma linha com o conteúdo novo |
| 3 | controller: 401 sem token, com token inválido e com runner revogado; 404 para job de outro runner; 413 por arquivo e por total ou quantidade do job; 422 para `../x` e `/etc/x`; 415 para o content-type errado. Domínio: os limites na transação |
| 4 | `prompt_test`: sem `files` o prompt não cita `CP_FILES_DIR`, e com `files` cita. `tasks_test`: um runner sem a capacidade gera o prompt sem a linha. `job_runner_test`: com o servidor respondendo 404, e também 500 (com as tentativas), o job termina `succeeded` com `files_failed: 2`. `channel test`: `files_failed` é gravado no job |
| 5 | `job_runner_test` em worktree: depois do job com `[arquivos]`, `git status --porcelain` do worktree vem vazio e os checks `clean`/`artifact_committed` passam. `claude_test`: `CP_FILES_DIR` é absoluto e fora de `dir` |
| 6 | `job_file_controller_test`: PNG `inline`, CSV, SVG e HTML como `attachment`, `nosniff` em todos, 404 para outro workspace e para um id inexistente. `task_live/show_test`: a miniatura e o link aparecem, e o aviso de `files_failed` também |
| 7 | **Novo** `e2e/tests/task-files.spec.ts`, com `@section Tarefas e pipelines` e `@flow A`. Uma tarefa com `[arquivos]` num runner real (`RunnerProcess` + `fake_claude`) mostra a miniatura, que tem `naturalWidth > 0`. O link do CSV, baixado com `page.request`, vem com `attachment`, e a aba "Anexos" agrupa os dois. Há `shot()` da seção e da aba. Page Object: `TasksPage` ganha os acessores |
| Segredos | `job_files_test` do runner: um arquivo cujo nome contém o valor de um segredo de `env` não sobe e entra em `files_failed`. O log do upload não traz o valor |

## Documentação

- **ADR nova `docs/adr/0041-arquivos-gerados-pela-etapa.md`.** Ela registra:
  - HTTP em vez do canal: binários grandes não passam pelo WebSocket nem pela outbox em
    memória, e um `PUT` idempotente aceita reenvio;
  - a pasta fora do git: os checks `clean`/`artifact_committed` e a branch ficam
    intactos;
  - o Postgres (`bytea`): sem infra nova, com cascata e backup juntos, atrás de uma
    interface de contexto que aceita object storage depois;
  - os limites;
  - o `content_type` pela extensão e o `attachment` para tudo que não é imagem raster;
  - capacidade sem subir a versão do protocolo.
- `docs/specs/protocolo-runner.md`, como na seção Protocolo.
- `docs/guias/instalacao.md`: o exemplo do nginx ganha
  `client_max_body_size 12m;`. O padrão do nginx é 1 MB e recusaria os uploads com 413.
- `docs/guias/deploy.md`: avisa que o nginx de `pipemaestro.app`, provisionado no
  repositório de infra `retro_hex_chat_infra`, precisa do mesmo `client_max_body_size`.
- `docs/plano/01-visao-arquitetura.md`: uma linha sobre os arquivos da etapa, onde ele
  descreve artefatos, se houver esse trecho. Sem contagens.

## Riscos

- **nginx de produção.** Com o padrão de 1 MB, só arquivos pequenos sobem até a infra
  ajustar o limite. O runner não quebra: o 413 vira `files_failed`, e a tela mostra o
  aviso. É uma ação de infra fora deste repositório, e o PR deve trazê-la como
  pré-requisito do deploy.
- **Memória.** O controller lê até 10 MB por requisição em memória, e o domínio grava
  numa só `INSERT`. Isso é aceitável dentro dos limites. A listagem nunca carrega
  `content` (`load_in_query: false`).
- **Banco.** Com até 50 MB por job, o banco cresce com o uso. Retenção e cota estão fora
  do escopo, e os arquivos saem em cascata com a tarefa ou o job. A ADR registra isso.
- **Migração.** Uma tabela nova e uma coluna nula em `jobs`. Não há backfill, e os dados
  existentes não mudam.
- **Concorrência.** O runner sobe em sequência, e o domínio confere os totais sob
  `FOR UPDATE` no job, então dois `PUT` simultâneos não estouram o limite. O upsert é
  idempotente.
- **Ordem no runner.** O upload passa a ser mais um passo no `Task` depois do agente. Se
  um job for cancelado nessa hora, ele espera o upload terminar, que é limitado pelas
  tentativas e pelo `receive_timeout` de 30 s por arquivo. O `JobRunner` não pode
  bloquear: nada de HTTP no `handle_info`.
- **Dialyzer.** Tipos de `Req.Response` e o `@spec` de `store/4` com os erros nomeados.
  `load_in_query` não muda o tipo do struct.
- **Cobertura.** Os três apps tocados ganham testes próprios, e o runner precisa do
  `files_server` para cobrir o caminho de erro.
- **e2e.** O `fake_claude` gera o PNG sem dependências externas (`printf`), para rodar
  igual no macOS e no Linux.

## Ordem de implementação (sugerida)

1. Protocolo: `JobFiles`, `Hello`, `Job` e os testes.
2. Domínio: migração, `JobFile`, `Files`, `files_failed`, `Prompt`/`start_stage` e os
   testes.
3. Web: o upload, o download e os testes de controller.
4. Runner: `JobFiles`, `Claude.env`, `JobRunner`, `Connection`, `fake_claude`,
   `files_server` e os testes.
5. Tela: o componente, a seção, a aba e o teste de LiveView, depois o spec Playwright e
   `make e2e.shots` em claro e escuro.
6. ADR 0041, o spec do protocolo e os guias. Por último, `make ci`.
