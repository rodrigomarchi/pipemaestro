# Documentação e resumo para revisão

## O que mudou e por quê

Arquivos que o agente gera no runner (screenshots, CSV, relatórios) sumiam com o worktree. Agora o runner os sobe como anexos do job e da etapa, e a página da tarefa os mostra.

### `apps/pipe_maestro_protocol`
- Módulo novo `JobFiles`: capacidade `files`, env `CP_FILES_DIR`, caminho do endpoint, limites e `valid_path?/1`.
- `Hello` anuncia `files`; `Job` reserva `CP_FILES_DIR`.

### `apps/pipe_maestro` (domínio)
- Tabela `job_files` (conteúdo em `bytea`, `unique (job_id, path)`) e coluna `jobs.files_failed` (ver `priv/repo/migrations`).
- Contexto `Jobs.Files`: `store/4` com limites sob `FOR UPDATE` e upsert; listagens sem o conteúdo.
- `Prompt` cita `$CP_FILES_DIR` só quando o runner tem a capacidade.

### `apps/pipe_maestro_web`
- `PUT /api/runner/jobs/:job_id/files` (Bearer do runner) e `GET /w/:slug/files/:id` (membros do workspace).
- Só imagem raster vai `inline`; o resto, `attachment`, com `nosniff` e CSP sandbox.
- `TaskLive.Show`: seção "Arquivos" por tentativa e aba "Anexos".

### `apps/pipe_maestro_runner`
- Pasta por job fora do git (`<workdir>/files/<job_id>`), upload depois do agente e fora do GenServer, com tentativas só para rede e 5xx.
- Symlinks, arquivos fora dos limites e nomes que contêm segredo são pulados e contados em `files_failed`.

## Protocolo
Mudou de forma **aditiva**; `protocol_version` continua 4 (padrão da ADR 0039).
- **Runner antigo** (sem `files`): funciona como antes. O prompt não cita `CP_FILES_DIR`, o endpoint nunca é chamado e a tela não mostra a seção.
- **Control plane antigo com runner novo**: o `PUT` dá 404 e não é repetido. O job termina com o status que teria, com `files_failed` no `job:finished`, e o canal antigo ignora a chave extra.

## Riscos e onde olhar
- **nginx de produção** (pré-requisito do deploy): o padrão de 1 MB devolve 413. É preciso `client_max_body_size 12m;`. O nginx de `pipemaestro.app` fica no repositório de infra, fora deste (ver `docs/guias/deploy.md`). Sem o ajuste, o runner não quebra, mas arquivos maiores aparecem como "não chegaram".
- **Banco**: até 50 MB por job em `bytea`, sem retenção nem cota (registrado na ADR 0041). Os arquivos saem em cascata com o job, a tarefa ou o workspace.
- **Download**: confira os cabeçalhos de `JobFileController` (SVG e HTML nunca inline) e o 404 entre workspaces.
- **Upload**: leitura do corpo em blocos e o limite sob `FOR UPDATE` em `Jobs.Files.store/4`.
- **Runner**: o upload é o último passo do `Task` pós-agente, e um cancelamento espera o fim dele.
- `JobLive` (job avulso) ainda não mostra os arquivos.

## Como verificar
```sh
make ci > /tmp/ci.log 2>&1; echo $?                  # 0
make e2e FILE=tests/task-files.spec.ts
make e2e.shots FILE=tests/task-files.spec.ts         # claro e escuro
```
Passos manuais:
1. Rode uma tarefa num runner novo com o agente copiando arquivos para `$CP_FILES_DIR`.
2. Na tentativa, veja a seção "Arquivos": miniatura da imagem e link do CSV.
3. Abra a aba "Anexos".
4. Baixe o CSV e confira que vem como `attachment`.
5. Acesse o link logado em outro workspace e confira o 404.

Resultado das etapas anteriores: `make ci` com exit 0 (05-ci.md) e `make e2e` completo verde (06-telas.md).

## ADRs e docs
- Nova: `docs/adr/0041-arquivos-gerados-pela-etapa.md`, com o índice em `docs/README.md` (que também ganhou a 0040, que faltava).
- `docs/specs/protocolo-runner.md`: §3 (capacidade `files`), §4.2 (`files_failed`), §4.4 (`CP_FILES_DIR`) e §4.8 (nova, "Arquivos do job").
- `docs/guias/instalacao.md` e `docs/guias/deploy.md`: `client_max_body_size`.
- `docs/plano/01-visao-arquitetura.md`: uma linha sobre os anexos da etapa.
