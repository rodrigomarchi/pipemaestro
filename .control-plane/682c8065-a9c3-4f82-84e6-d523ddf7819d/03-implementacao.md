# Implementação: arquivos gerados no runner como anexos da etapa

Implementei o plano de `01-plano.md` até os testes de `02-testes.md` passarem.
Mudei três testes. Os motivos estão em "Testes corrigidos".

`make ci.quick` sai 0. O spec novo `e2e/tests/task-files.spec.ts` passa, e
`make e2e.shots FILE=tests/task-files.spec.ts` foi conferido em claro e escuro.
Rodei com `E2E_FORGEJO_PORT=4813 E2E_GITHUB_PORT=4814`, porque outro worktree usava as
portas padrão. A suíte e2e completa está em "Verificação".

## O que mudou, por app

### `apps/pipe_maestro_protocol`

- **Novo** `PipeMaestroProtocol.JobFiles`: `capability/0` (`"files"`), `env/0`
  (`"CP_FILES_DIR"`), `path/1`, `max_file_bytes/0` (10 MiB), `max_job_bytes/0`
  (50 MiB), `max_files/0` (100) e `valid_path?/1`.
- `Hello.capabilities/0` ganha `"files"`.
- `Job` passa a reservar a env `CP_FILES_DIR`. O moduledoc cita a env e `files_failed`
  no `job:finished`.
- A `protocol_version` continua 4. A mudança é aditiva, por capacidade.

### `apps/pipe_maestro` (domínio)

- Migração `20261116090000_create_job_files.exs`:
  - tabela `job_files` (`bytea`), com `unique (job_id, path)`, índices em
    `stage_run_id` e `workspace_id` e cascata pelo job, pelo stage run e pelo
    workspace;
  - coluna `jobs.files_failed`.
- `PipeMaestro.Jobs.JobFile`: o campo `content` tem `load_in_query: false`.
- `PipeMaestro.Jobs.Files`:
  - `store/4` confere o runner dono, o caminho e o tamanho. Numa transação com
    `FOR UPDATE` no job, confere os totais sem contar o arquivo substituído e faz o
    upsert;
  - `content_type` vem de `MIME.from_path/1`, com `{:mime, "~> 2.0"}` declarado no
    `mix.exs`;
  - também tem `list_for_stage_run/1`, `list_for_task/1`, `get_for_download/2`,
    `image?/1` e `limits/0`.
- `Jobs.Job`: `files_failed` (≥ 0) entra no `finish_changeset/3`. O canal não precisou
  mudar: ele já passa o payload inteiro a `finish_job/3`.
- `Pipelines.Prompt`: com `context[:files]`, o cabeçalho ganha a regra de copiar para
  `$CP_FILES_DIR`.
- `Tasks.start_stage`: `files: Runners.capable?(runner, "files")`, com o runner da
  tarefa. Ele usa o runner pré-carregado ou o lê do banco.

### `apps/pipe_maestro_web`

- `PUT /api/runner/jobs/:job_id/files` → `RunnerFileController`:
  - autentica com Bearer `cpr_…`;
  - exige `application/octet-stream`;
  - recusa logo pelo `Content-Length` acima do limite e lê o corpo em blocos de 1 MB;
  - responde 201, 401, 404, 413 (com `limit`), 415 ou 422;
  - não registra o corpo nem o caminho no log.
- `GET /w/:workspace_slug/files/:id` → `JobFileController`:
  - só membros do workspace;
  - imagem raster vai `inline` e o resto como `attachment`, com
    `filename*=UTF-8''…`, `nosniff`, `CSP sandbox` e `cache-control: private,
    max-age=3600`.
- **Novo** `JobFileComponents`:
  - `files/1` mostra as imagens numa grade de miniaturas, cada `<img loading=lazy>`
    dentro do link que abre em nova aba, e os outros arquivos numa lista com ícone,
    nome, tamanho e link;
  - `files_failed/1` mostra o aviso (Petal `<.alert color="warning">`).
- `TaskLive.Show`:
  - carrega `Files.list_for_task/1` no mount e a cada `task_updated`;
  - a seção "Arquivos" de cada tentativa fica logo depois do artefato;
  - a aba nova "Anexos" (`?aba=anexos`, com contador) agrupa os arquivos por etapa e
    tentativa, das mais recentes para as mais antigas.

### `apps/pipe_maestro_runner`

- **Novo** `PipeMaestroRunner.JobFiles`:
  - `dir/2`, `prepare/2` e `clear/1`;
  - `collect/2` percorre a pasta com `File.lstat`, sem seguir symlinks. Ele aplica os
    limites e o filtro de segredos (valores de 6 bytes ou mais, como o
    `LogCollector`), e o aviso de um arquivo pulado por segredo não traz o nome;
  - `upload/5` usa `Req.put` com `retry: :transient`, `max_retries: 2` e backoff de
    0,5 s, 1 s e 2 s. Um 4xx não se repete, e o `receive_timeout` é de 30 s.
- `Claude.env/3` passa `CP_FILES_DIR` absoluto, ou a remove (`false`) sem pasta.
- `JobRunner`, com as opções `:files` e `:files_req_options`:
  - cria a pasta no início do job e a limpa no `init`;
  - quando há pasta, `after_exit` sempre passa pelo `Task` de `after_agent`, e o
    upload é o último passo, fora do GenServer;
  - `files_failed` (pulados + falhas) só vai quando é maior que zero;
  - a pasta é apagada em background depois do `job:finished`, e também em `done/3`.
- `Connection` passa `files: %{url: config.url, token: config.token}`.

### Documentação

- **Nova** `docs/adr/0041-arquivos-gerados-pela-etapa.md`.
- `docs/specs/protocolo-runner.md`:
  - a capacidade `files` (§3);
  - `files_failed` no `job:finished` (§4.2);
  - `CP_FILES_DIR` em §4.4;
  - a seção nova §4.8 "Arquivos do job".
- `docs/guias/instalacao.md`: `client_max_body_size 12m;` no exemplo do nginx.
- `docs/guias/deploy.md`: o nginx de `pipemaestro.app`, na infra, precisa do mesmo
  ajuste. **É pré-requisito do deploy**: sem ele, os arquivos acima de 1 MB voltam com
  413 e aparecem como "não chegaram".
- `docs/plano/01-visao-arquitetura.md`: uma linha sobre os anexos da etapa.

## Testes corrigidos

1. **`task_live_test.exs` (aba Anexos).** O teste procurava
   `stage-run-file-a-1-dados/r.csv` dentro de `task-panel-anexos`. Isso exigiria o
   mesmo `data-testid` duas vezes na página: na tentativa (aba Etapas) e na aba Anexos.
   Os painéis ocultos continuam no DOM, então o spec Playwright, que usa
   `getByTestId("stage-run-file-…")`, cairia na violação de strict mode. Por isso a aba
   usa o prefixo próprio `task-attachment-<key>-<attempt>-<path>`, e o teste passou a
   procurar `task-attachment-a-1-dados/r.csv`. A asserção continua igual: o arquivo
   está no grupo da tentativa, dentro da aba.
2. **`e2e/tests/task-files.spec.ts` (sem sessão).** `request.get` segue o redirect
   até `/login`, que responde 200, então `not.toBe(200)` falhava mesmo com o download
   negado. Agora o spec usa `maxRedirects: 0` e confere `302` com `location` em
   `/login`. O 404 para quem é de outro workspace continua coberto em
   `job_file_controller_test.exs`. O `@flow A [todo]` virou `[done]`.
3. **Ordem dos aliases** em `files_test.exs`, `runner_file_controller_test.exs` e
   `job_file_controller_test.exs`, para o `credo --strict`. Nenhuma asserção mudou.

Também acrescentei uma asserção em `job_files_test.exs` do runner. Ela confere que o
log do arquivo pulado por segredo não traz o valor, como o plano pedia na linha
"Segredos".

## Compatibilidade

- **Runner antigo** (sem `"files"`): o prompt não cita `CP_FILES_DIR`
  (`tasks_test`), o endpoint nunca é chamado e a tela não mostra a seção.
- **Control plane antigo**: o `PUT` recebe 404 e não é repetido. O job termina com o
  status que teria e `files_failed: 2` (`job_runner_test`). O canal antigo ignora a
  chave extra, porque o `cast` só lê os campos conhecidos.

## Como verificar

```sh
make ci.quick > /tmp/ciq.log 2>&1; echo $?          # 0
(cd apps/pipe_maestro && mix test test/pipe_maestro/jobs/files_test.exs)
(cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/controllers/runner_file_controller_test.exs \
  test/pipe_maestro_web/controllers/job_file_controller_test.exs test/pipe_maestro_web/live/task_live_test.exs)
(cd apps/pipe_maestro_runner && mix test test/pipe_maestro_runner/job_files_test.exs test/pipe_maestro_runner/job_runner_test.exs)
make e2e FILE=tests/task-files.spec.ts
make e2e.shots FILE=tests/task-files.spec.ts       # task-files/02-stage-run-files*, 03-task-attachments*
```

## Verificação

- `make ci.quick`: exit 0. Os resultados de teste por app:

  | App | Testes |
  |---|---|
  | `pipe_maestro_protocol` | 111 |
  | `pipe_maestro` | 523 |
  | `pipe_maestro_web` | 473 |
  | `pipe_maestro_runner` | 240 |

- `make e2e FILE=tests/task-files.spec.ts`: passa.
- `make e2e.shots`: conferi a seção da tentativa e a aba "Anexos" em claro e escuro. A
  miniatura carrega, e o nome, o tamanho, o link do CSV e o contador 2 aparecem sem
  quebra.
- Suíte e2e completa (`make e2e`): a primeira rodada foi morta por um SIGKILL de fora (exit 137, provavelmente a limpeza de porta de outra sessão). A segunda rodada ainda não tinha terminado quando esta etapa fechou. A etapa seguinte deve confirmá-la com `make e2e` e `make ci`.
- Dialyzer (`make ci`) fica para o fim do bloco, na etapa seguinte.
