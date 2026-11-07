# Testes que falham: arquivos gerados no runner como anexos da etapa

Base: o plano em `01-plano.md`. Só há código de teste nesta etapa: nenhum módulo de
`lib/` foi criado ou alterado.

## O que foi escrito

### `apps/pipe_maestro_protocol`

- **Novo** `test/pipe_maestro_protocol/job_files_test.exs`: `JobFiles.capability/0`
  (`"files"`), `env/0` (`"CP_FILES_DIR"`), `path/1`, os limites
  (`max_file_bytes/0` 10 MiB, `max_job_bytes/0` 50 MiB, `max_files/0` 100) e
  `valid_path?/1` (aceita relativo e subpasta, até 255 bytes; recusa vazio, `..`,
  absoluto, `./`, `a/./b`, `a//b`, barra final, `\`, NUL, 256 bytes e não-string).
- `pipe_maestro_protocol_test.exs`: `"files" in Hello.capabilities()`.
- `job_test.exs` ("rejects a bad context"): um segredo `CP_FILES_DIR` é recusado
  (`@reserved_env`).

### `apps/pipe_maestro` (domínio)

- **Novo** `test/pipe_maestro/jobs/files_test.exs` (`PipeMaestro.Jobs.Files`):
  - `store/4` grava `path`, `content_type` (`image/png`, `text/csv`,
    `application/octet-stream` para extensão desconhecida), `byte_size`, `sha256` (hex
    minúsculo), `job_id`, `stage_run_id` e `workspace_id`;
  - reenviar o mesmo caminho substitui (mesmo `id`, uma linha só);
  - outro runner, id inexistente e id inválido → `{:error, :not_found}`;
  - caminho inválido → `{:error, :invalid_path}`;
  - acima de `max_file_bytes` → `{:error, :too_large}`;
  - total do job (5 × 10 MiB) e quantidade (100) → `{:error, :too_large}`, mas
    substituir um arquivo existente continua aceito;
  - `list_for_stage_run/1` por `path` e `list_for_task/1` (`%{stage_run_id => [...]}`),
    os dois com `content: nil` (`load_in_query: false`);
  - `get_for_download/2` traz o `content`; outro workspace, id inexistente ou inválido
    → `nil`;
  - `image?/1` só para `png`, `jpeg`, `gif` e `webp` (SVG, HTML, CSV não);
  - `limits/0` → `%{max_file_bytes:, max_job_bytes:, max_files:}` do protocolo.
- `jobs_test.exs`: `finish_job/3` guarda `"files_failed"` e deixa `nil` sem ele.
- `pipelines/prompt_test.exs`: com `files: true` o prompt cita `$CP_FILES_DIR` e
  "copiados"; sem `files` (ou `false`) não cita `CP_FILES_DIR`.
- `tasks_test.exs`: o prompt do `job:assign` só cita `$CP_FILES_DIR` depois que o
  runner anuncia `"files"` no `Hello`.

### `apps/pipe_maestro_web`

- **Novo** `controllers/runner_file_controller_test.exs`
  (`PUT /api/runner/jobs/:job_id/files?path=…`): 201 com
  `{path, byte_size, sha256, content_type}` e ligação ao stage run; reenvio substitui;
  401 sem token, token inválido e runner revogado; 404 `not_found` igual para job de
  outro runner e inexistente; 413 `{"error": "too_large", "limit"}` acima do limite do
  arquivo e com o job cheio; 422 `invalid_path`; 415 para `application/json`.
- **Novo** `controllers/job_file_controller_test.exs` (`GET /w/:slug/files/:id`): PNG
  `inline; filename*=UTF-8''login.png`, `nosniff`, CSP com `sandbox`,
  `cache-control: private, max-age=3600`; CSV, SVG e HTML como `attachment`; 404 para
  quem é de outro workspace (pelo slug alheio e pelo próprio) e para id inexistente;
  sem sessão, redireciona ao login.
- `channels/runner_channel_test.exs`: `job:finished` com `"files_failed" => 2` grava
  no job.
- `live/task_live_test.exs`:
  - a seção `stage-run-files-a-1`, o item, a miniatura (`img` com o testid
    `stage-run-file-thumb-…` e `src` do download), o link de download do CSV, nenhuma
    miniatura para o CSV, e o aviso `stage-run-files-failed-a-1` com o número;
  - a aba `anexos`: `task-no-attachments` antes, `task-tab-count-anexos` = 2 depois e
    o grupo `task-attachments-a-1` dentro de `task-panel-anexos`;
  - `?aba=anexos` abre a aba.

### `apps/pipe_maestro_runner`

- `test/support/fake_claude`: modo `[arquivos]`. Com `CP_FILES_DIR`, grava um PNG 1×1
  (`printf` em octal), `dados/r.csv` e o symlink `atalho.png`; roda antes do
  `[falha]`, então uma etapa que falha também deixa os arquivos.
- **Novo** `test/support/files_server.exs` (`PipeMaestroRunner.Test.FilesServer`):
  Bandit que grava cada `PUT` (job, `path`, `authorization`, `content-type`, corpo) e
  responde 201 ou o status de `respond/2`. Carregado no `test_helper.exs`.
- **Novo** `pipe_maestro_runner/job_files_test.exs` (`PipeMaestroRunner.JobFiles`):
  `dir/2`, `prepare/2`, `clear/1`; `collect(dir, env)` → `{files, skipped}`, com
  `files` em ordem de `path` (cada um com `.path`), sem symlinks nem pasta por symlink,
  e contando em `skipped` o acima do limite, o excedente de quantidade e o nome com
  valor de segredo; pasta inexistente → `{[], 0}`; `upload(files, url, token, job_id,
  req_options)` → `%{uploaded, failed}`, com Bearer e `application/octet-stream`, sem
  repetir 4xx, repetindo 5xx e contando tudo como falha sem servidor.
- `job_runner_test.exs`, `describe "the job's files"` (opções `files: %{url, token}` e
  `files_req_options: [retry_delay: …]`):
  - sobe `a.png` e `dados/r.csv` (não o symlink) e apaga `<workdir>/files/<job>`;
  - a pasta fica fora do diretório do job, e um job seguinte não reenvia nada;
  - um job `failed` também sobe os arquivos;
  - 404 do control plane: uma tentativa por arquivo, job `succeeded` com
    `files_failed: 2`;
  - 500: mais de uma tentativa por arquivo, `files_failed: 2`;
  - sem `:files`: nada é enviado e não há pasta (**passa já**, guarda a
    compatibilidade);
  - restos de `<workdir>/files` somem quando o `JobRunner` sobe;
  - no worktree de uma tarefa, os checks `clean` e `artifact_committed` passam,
    `git status --porcelain` vem vazio e `git ls-files` não tem os arquivos.
- `describe "Claude"`: `Claude.env(job, telemetry, files_dir)` passa
  `CP_FILES_DIR` absoluto, e `{~c"CP_FILES_DIR", false}` sem pasta.

### e2e

- **Novo** `e2e/tests/task-files.spec.ts` (`@section Tarefas e pipelines`,
  `@flow A [todo]`): runner real com o `fake_claude`, tarefa "Prompt único" com
  `[arquivos]`; a seção da tentativa `executar-1` com os dois arquivos e sem o
  symlink; a miniatura com `naturalWidth > 0`; o PNG `inline` com `nosniff`; o CSV
  `attachment` com o conteúdo certo; um contexto sem sessão não baixa; a aba "Anexos"
  com contador 2 e o grupo da tentativa; nada no worktree nem no git. `shot()` da
  seção e da aba.
- `e2e/pages/TasksPage.ts`: `openTab`, `tabCount`, `stageRunFiles`, `stageRunFile`,
  `stageRunFileThumb`, `stageRunFileDownload`, `stageRunFilesFailed`, `attachments` e
  `noAttachments`.

## Decisões de interface que os testes fixam

O plano deixava estas formas em aberto. Os testes escolheram:

- `Claude.env/3`: o terceiro argumento é o caminho da pasta (ou `nil`).
- `PipeMaestroRunner.JobFiles.collect/2` recebe o `env` do job (mapa) e devolve
  `{files, skipped}`; cada item de `files` tem `.path` relativo.
- `PipeMaestroRunner.JobFiles.upload/5` aceita `retry_delay` em `req_options`
  (opção do `Req`), para os testes não esperarem o backoff.
- `Files.limits/0` devolve um mapa com as três chaves.
- A miniatura leva o testid no próprio `<img>`, para o e2e ler `naturalWidth` sem
  seletor de estrutura.
- Os testes não usam `%JobFile{…}` nem `%Job{files_failed: …}` em padrões: o
  compilador recusaria a struct e a chave que ainda não existem. Eles usam
  `%{__struct__: JobFile, …}`, `struct/2` e `Map.get/2`, que falham em tempo de
  execução.

## Falhas: o motivo de cada uma

`mix test` a partir da raiz: **57 falhas, todas nos testes novos ou no trecho novo de
um teste existente**. Todo o resto passa.

| App | Resultado |
|---|---|
| `pipe_maestro_protocol` | 103/111, 8 falhas |
| `pipe_maestro` | 508/523, 15 falhas |
| `pipe_maestro_web` | 458/473, 15 falhas |
| `pipe_maestro_runner` | 221/240, 19 falhas |

### Protocolo (8)

O módulo `PipeMaestroProtocol.JobFiles` ainda não existe:

```
** (UndefinedFunctionError) function PipeMaestroProtocol.JobFiles.valid_path?/1 is undefined (module PipeMaestroProtocol.JobFiles is not available)
```

A capacidade e a env reservada ainda não foram acrescentadas:

```
code:  assert "files" in Hello.capabilities()
right: ["doctor", "git_credential", "health", "logs", "scratch"]

code:  assert {:error, "env" <> _} = Job.new(Map.put(base, :env, %{"CP_FILES_DIR" => "/tmp"}))
right: {:ok, %PipeMaestroProtocol.Job{...}}
```

### Domínio (15)

`Files` e `JobFile` não existem (12 testes de `files_test`, inclusive os que param
antes em `PipeMaestroProtocol.JobFiles.max_file_bytes/0`):

```
** (UndefinedFunctionError) function PipeMaestro.Jobs.Files.store/4 is undefined (module PipeMaestro.Jobs.Files is not available)
** (UndefinedFunctionError) function PipeMaestro.Jobs.JobFile.__struct__/0 is undefined (module PipeMaestro.Jobs.JobFile is not available)
```

O job ainda não tem `files_failed`, e o prompt não sabe de `CP_FILES_DIR`:

```
code:  assert Map.get(finished, :files_failed) == 2
left:  nil

code:  assert prompt =~ "$CP_FILES_DIR"          (prompt_test e tasks_test)
left:  "Você está executando a etapa \"Etapa A\" (1) ... Faça A: O botão não responde"
```

### Web (15)

A rota de upload não existe, então o router responde 404 (7 testes do
`RunnerFileController`; os dois de 413 param antes, em
`PipeMaestroProtocol.JobFiles.max_*`):

```
** (RuntimeError) expected response with status 201, got: 404, with body: "Not Found"
** (RuntimeError) expected response with status 401, got: 404, with body: ...
** (RuntimeError) expected content-type for json, got: "text/html; charset=utf-8"
```

O download depende de `Files.store/4` para preparar o arquivo (4 testes):

```
** (UndefinedFunctionError) function PipeMaestro.Jobs.Files.store/4 is undefined
```

O canal ainda não grava `files_failed`, e a tela não tem a seção nem a aba:

```
code:  assert Map.get(Repo.get!(Job, job.id), :files_failed) == 2
left:  nil

Expected truthy, got false
code: assert has_element?(view, "[data-testid=task-no-attachments]")
code: assert has_element?(view, "[data-testid=task-tab-anexos]")
```

### Runner (19)

`PipeMaestroRunner.JobFiles` não existe (11 testes):

```
** (UndefinedFunctionError) function PipeMaestroRunner.JobFiles.collect/2 is undefined (module PipeMaestroRunner.JobFiles is not available)
```

O `JobRunner` ignora `:files`: não passa `CP_FILES_DIR`, não sobe nada e não limpa a
pasta (7 testes):

```
code:  assert uploads(ctx.server) == [{"j1", "a.png"}, {"j1", "dados/r.csv"}]
left:  []

code:  assert finished["files_failed"] == 2
left:  nil

code: refute File.exists?(stale)
Expected false or nil, got true
```

No teste do worktree, as asserções de `clean`/`artifact_committed` e do
`git status` já passam (o agente não grava nada sem a env), e a falha é a do
upload. `Claude.env/3` não existe:

```
** (UndefinedFunctionError) function PipeMaestroRunner.Claude.env/3 is undefined or private. Did you mean: env/1, env/2
```

O teste "without an upload configured" **passa**, como esperado: ele protege o
caminho do runner sem upload.

### Avisos de compilação

`mix test` mostra avisos "is undefined (module … is not available)" nos arquivos de
teste novos, pelos mesmos módulos ausentes. Eles somem com a implementação. Por isso
`make ci` (com `--warnings-as-errors`) não é o gate desta etapa.

## e2e

`make e2e.typecheck` passa.

`make e2e FILE=tests/task-files.spec.ts` falha pelo motivo certo. O login do runner,
o projeto, os pipelines e a tarefa funcionam, e a tarefa chega a "Concluída". A
primeira asserção nova é a que falha, porque a seção de arquivos da tentativa não
existe:

```
Error: expect(locator).toBeVisible() failed
  - waiting for getByTestId('stage-run-files-executar-1')
> 74 |     await expect(tasks.stageRunFiles("executar", 1)).toBeVisible();
  1 failed
    [chromium] › tests/task-files.spec.ts:27:7 › Task files › the files a stage leaves in CP_FILES_DIR show on the task
```

Outro worktree rodava e2e ao mesmo tempo, com o Forgejo falso na porta 4013. Por isso
esta execução usou `E2E_FORGEJO_PORT=4813 E2E_GITHUB_PORT=4814`. O spec não depende
dessas portas.

Quando o spec passar, a implementação troca o `@flow A [todo]` por `[done]`.

## Cuidado para as próximas etapas

Não rode `test/support/fake_claude` à mão dentro deste worktree. O caminho casa com
`*/worktrees/*`, e o script herda o `CP_ARTIFACT_PATH` da plataforma. Por isso ele faz
commit de `fake-claude.txt` e de um artefato falso. Aconteceu aqui, e o commit foi
desfeito antes do push. Para testá-lo, use uma pasta temporária com
`env -u CP_ARTIFACT_PATH`.
