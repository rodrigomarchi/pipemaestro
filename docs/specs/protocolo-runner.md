# Protocolo runner ↔ control plane (v3)

> Status: v3, implementada em `apps/pipe_maestro_protocol`, que é a fonte da
> verdade das constantes e dos formatos `Hello`, `Job` e `JobEvent`. Ela cobre login,
> conexão, jobs (seção 4) e o contexto das etapas de tarefa (seção 4.4). Leases e
> dispatcher entram em versões seguintes. As versões anteriores nunca foram
> distribuídas: v1 cobria só login e conexão, e v2 trazia jobs sem contexto.

## Princípios

- **A conexão parte sempre do runner.** O cliente não abre nenhuma porta de entrada.
- **O runner tem identidade própria.** Ele recebe um token próprio e nunca guarda a
  credencial de uma pessoa. O control plane armazena só o SHA-256 desse token.
- **A versão é declarada em toda conexão.** O control plane aceita as versões de
  `PipeMaestroProtocol.supported_versions/0`.

## 1. Login (device flow)

Segue o modelo do OAuth 2.0 Device Authorization Grant (RFC 8628).

### 1.1 Pedir um código

`POST /api/runner/device/code`

```json
{
  "hello": {
    "protocol_version": 3, "runner_version": "2026-11-04.01",
    "hostname": "build-01", "os": "linux", "arch": "x86_64",
    "labels": ["linux", "docker"], "capacity": 4
  },
  "name": "Servidor de build"
}
```

`name` é opcional; o padrão é o hostname.

`runner_version` é uma string de 1 a 120 bytes. Os runners deste repositório mandam
`AAAA-MM-DD.NN` numa release, `AAAA-MM-DD.NN+dev.<commit>` ou `dev+<commit>` fora dela
(`PipeMaestroProtocol.Version`, [ADR 0016](../adr/0016-esquema-de-versao.md)).
O formato é informativo: outros valores continuam aceitos e só não recebem o selo
"desatualizado".

A resposta é `200`:

```json
{
  "device_code": "<segredo, só o runner conhece>",
  "user_code": "WDJB-MJHT",
  "verification_uri": "https://plataforma/runners/activate",
  "verification_uri_complete": "https://plataforma/runners/activate?code=WDJB-MJHT",
  "expires_in": 600,
  "interval": 5
}
```

O `user_code` tem 8 consoantes (sem vogais e sem caracteres ambíguos); maiúsculas,
espaços e hífen não importam na digitação.

### 1.2 Aprovação

A pessoa abre `verification_uri` já logada, confere o pedido (hostname, SO, labels e
capacidade), escolhe um workspace do qual é membro e o nome do runner, e então
**aprova** ou **recusa**.

### 1.3 Polling

`POST /api/runner/device/token` com `{"device_code": "..."}`, a cada `interval` segundos.

| Resposta | Significado | O que o runner faz |
|---|---|---|
| `200` `{runner_token, runner: {id, name}, workspace: {name, slug}}` | aprovado | grava as credenciais e termina |
| `400` `{"error": "authorization_pending"}` | ainda não aprovado | espera `interval` e tenta de novo |
| `400` `{"error": "slow_down"}` | consultou rápido demais | soma 5 s ao intervalo |
| `400` `{"error": "access_denied"}` | recusado | encerra |
| `400` `{"error": "expired_token"}` | o código expirou | encerra |
| `400` `{"error": "invalid_request"}` | código desconhecido ou já usado | encerra |

O token (`cpr_…`) é emitido uma única vez, na primeira consulta depois da aprovação.

## 2. Conexão

O runner abre um WebSocket Phoenix (serializador v2) em
`ws(s)://<plataforma>/runner/socket/websocket?token=<runner_token>&protocol_version=3`.

Token inválido, runner revogado ou versão não suportada fazem a plataforma recusar
o upgrade com **HTTP 403**. Uma nova tentativa não resolve: o runner encerra e
orienta a pessoa a fazer o login de novo. Para qualquer outra queda, o runner
reconecta com backoff (0,5 s, 1 s, 2 s, 5 s, 10 s e depois 30 s).

## 3. Canal `runner:<runner_id>`

- **Join:** o payload é o `Hello` (o mesmo formato da seção 1.1), acrescido de:
  - `running_job_ids`: os jobs que o runner ainda está executando (vazio se omitido);
  - `directories`: os diretórios de código que ele oferece, ou seja, o primeiro nível
    da raiz com que foi iniciado (`[{"name": "app", "git": true}, …]`, até 500);
  - `agent` (opcional): `{"cli_version", "auth"}`, a versão do CLI do agente (`null`
    se não foi encontrado) e como ele se autentica: `api_key` (a chave própria do
    runner) ou `login` (o login da máquina).

  O runner manda um `Hello` novo a cada (re)join. A resposta é
  `{"runner_id", "name", "workspace"}`. Entrar no tópico de outro runner dá
  `{"reason": "unauthorized"}`, e um `Hello` inválido dá `{"reason": "invalid_hello"}`.
- **O que acontece no join:** o control plane grava o `Hello` (labels, capacidade,
  versão, hostname, SO e arch) e passa a mostrar o runner como **online** no
  workspace enquanto o canal existir.
- **Heartbeat:** é o do Phoenix. O cliente envia um a cada 30 s, e o servidor
  derruba a conexão depois de 60 s sem receber nenhum.
- **Revogação:** o control plane manda `disconnect` para o socket
  `runner_socket:<id>`. A reconexão que vem em seguida recebe 403.

## 4. Jobs

Um job é um prompt que um membro do workspace envia a um runner escolhido por ele.
O runner o executa com o agente CLI e reporta eventos e o desfecho. Executa até
`capacity` jobs ao mesmo tempo; jobs que dividem o mesmo lugar esperam um pelo outro,
na ordem: as etapas de uma tarefa (o worktree dela), os jobs num diretório sem
worktree (o diretório) e os jobs avulsos (o workdir). Todas as mensagens trafegam no
canal `runner:<runner_id>`.

### 4.1 Control plane → runner

| Evento | Payload | O que o runner faz |
|---|---|---|
| `job:assign` | `{"id", "prompt"}` (`PipeMaestroProtocol.Job`; prompt de até 32 000 bytes) | põe o job na fila local; ignora um job que já tem na fila ou em execução |
| `job:cancel` | `{"job_id"}` | tira da fila, ou interrompe o job em execução (SIGTERM ao grupo de processos e, depois de 5 s, SIGKILL) |

No join, o control plane reenvia `job:assign` para cada job ainda `queued` daquele
runner.

### 4.2 Runner → control plane

Cada mensagem recebe uma resposta: `ok`, ou `error` com `{"reason"}`, onde `reason`
é `not_found`, `not_queued`, `finished`, `invalid` ou `unknown_message`.

| Evento | Payload |
|---|---|
| `job:started` | `{"job_id"}` |
| `job:event` | `{"job_id", "seq", "type", "data"}`, com `seq` contando a partir de 1 |
| `job:finished` | `{"job_id", "status", "exit_code", "result", "cost_usd", "duration_ms", "num_turns", "error"?}`, com `status` igual a `succeeded`, `failed` ou `canceled` |
| `job:delta` | `{"job_id", "text"}`: o que o agente está escrevendo (até 4 KB do fim), no máximo a cada 250 ms. Sem resposta, fora da outbox e não guardado |
| `job:telemetry` | `{"job_id", "records"}`: até 200 registros `{"name", "at", "attrs"}` da telemetria OpenTelemetry do CLI (`PipeMaestroProtocol.Telemetry`, ADR 0015). Pode chegar depois do `job:finished`; a outbox o descarta primeiro, como os eventos, quando enche |

Para a auditoria (ADR 0015), o `job:finished` também traz o que a execução contou de
si:

- `session_id`, `cli_version`, `model`, `stop_reason` e `result_subtype`;
- os tempos `duration_api_ms`, `ttft_ms` e `wall_ms` (o processo do agente, medido
  pelo runner);
- `usage` (`fresh_input`, `cache_read`, `cache_creation`, `output`, `thinking`) e
  `model_usage` (por modelo: esses tokens e `cost_usd`);
- `permission_denials` e `subagents`;
- `environment`: `tools`, `mcp_servers`, `agents`, `skills`, `slash_commands`,
  `plugins`, `permission_mode`, `auth` e `output_style`;
- `stderr`: o fim do que o CLI escreveu lá, até 16 KB.

Os tipos de `job:event` (`PipeMaestroProtocol.JobEvent`) resumem as linhas do
`claude -p --output-format stream-json`. Os textos são cortados em 32 KB e os
argumentos de ferramenta em 16 KB.

| `type` | `data` |
|---|---|
| `system` | `text`, `session_id`, `model`, `cwd`, `version`, `auth`, `permission_mode`, `output_style`, `tools`, `mcp_servers` (`name`, `status`), `agents`, `skills`, `slash_commands`, `plugins` (`name`, `version`) |
| `thinking` | `text` (vazio quando o CLI não mostra o raciocínio), `duration_ms` |
| `assistant_text` | `text` |
| `tool_use` | `id`, `name`, `text` (o argumento principal: comando, arquivo, padrão…), `input` (ferramentas conhecidas) ou `arguments` (JSON, para as demais, MCP incluídas) |
| `tool_result` | `tool_use_id`, `text`, `is_error`, `decision` (`decision`, `source`: a permissão que deixou a ferramenta rodar) |
| `api_retry` | `attempt`, `max_retries`, `delay_ms`, `status`, `error`, `text` |
| `compact` | `trigger`, `pre_tokens`, `text` |
| `permission_denied` | `tool_name`, `tool_use_id`, `text` |
| `rate_limit` | `status`, `window`, `utilization` (por janela, de 0 a 1), `resets_at` |
| `result` | `text`, `is_error`, `subtype`, `stop_reason`, `terminal_reason`, `session_id`, `cost_usd`, `duration_ms`, `duration_api_ms`, `ttft_ms`, `num_turns`, `usage`, `model_usage`, `permission_denials`, `errors`, `subagents`, `structured_output` |

Eventos do trabalho de um subagente levam `parent_tool_use_id`. O primeiro evento de
cada mensagem do agente leva `usage`: `message_id`, `model`, `fresh_input`,
`cache_read`, `cache_creation`, `input` (os três somados) e `output`. Uma mensagem
dividida em várias linhas leva os tokens só no primeiro evento.

O par `(job_id, seq)` é único, então um evento reenviado é ignorado.

**Entrega confiável.** O runner guarda cada mensagem desta seção até receber a
resposta e, depois de cada join, reenvia em ordem o que não foi respondido. Uma
resposta `error` também encerra a mensagem, porque reenviar não mudaria a resposta. O
control plane é idempotente: `seq` repetido é ignorado, e um `job:started` ou
`job:finished` repetido responde `not_queued` ou `finished`. Um job com mensagens não
confirmadas entra em `running_job_ids` do `Hello`, para que a reconciliação não o
falhe antes do reenvio. A outbox vive em memória: se o runner reinicia, ela se perde e
os jobs em execução viram `failed`.

### 4.3 Diretórios

Se os diretórios da raiz mudam com o runner online, ele envia
`runner:directories` com `{"directories": [...]}`. O formato é o mesmo do `Hello`, e a
resposta é `ok` ou `error` (`invalid`). O runner verifica a raiz a cada minuto.

### 4.4 Contexto de etapa

O `job:assign` de uma etapa de tarefa traz, além de `id` e `prompt`, estes campos
opcionais:

Nenhum campo restringe o agente: o runner sempre o roda com todas as permissões
(`--dangerously-skip-permissions`, ADR 0018) e ignora um `permissions` que um control
plane antigo ainda mande.

| Campo | Uso no runner |
|---|---|
| `directory` | um dos `directories` anunciados; o job roda nele (ou no worktree, abaixo) |
| `worktree` | `{"task_id", "branch"}`: roda em `<workdir>/worktrees/<task_id>`, um `git worktree` do diretório no branch dado, criado na primeira etapa e reaproveitado nas seguintes |
| `output_schema` | passado em `--json-schema`; a saída validada volta em `structured_output` |
| `model`, `max_budget_usd` | passados em `--model` e `--max-budget-usd` |
| `artifact_path` | caminho relativo onde o agente escreve o artefato da etapa; vai na env `CP_ARTIFACT_PATH`, e o runner devolve o conteúdo (até 64 KB). Sem o campo, o runner tira `CP_ARTIFACT_PATH` do ambiente do agente, para que um valor herdado não vaze para o job |
| `timeout_ms` | tempo máximo do agente; ao estourar, o runner encerra o grupo de processos e o job falha |
| `system_prompt`, `mcp_config`, `agents`, `agent` | o contexto do pipeline e o agente da etapa (ADR 0011): vão em `--append-system-prompt`, `--mcp-config`, `--agents` e `--agent` |
| `delivery` | `{"commit_message", "push"?, "pr"?, "issue_comment"?}`: o que o runner faz com a etapa que passou (ADR 0013): commit, push do branch, PR em rascunho (`{"title", "body", "ready"}`) e comentário na issue (`{"url", "body"}`). O `job:finished` traz `delivery` com `{"commit", "pushed", "pr_url", "commented", "error"?}` |
| `parallel` | `true` numa etapa de um grupo (ADR 0014): roda junto com as irmãs no worktree da tarefa, sem esperar por elas |
| `env` | `{"NOME": "valor"}`: os segredos do workspace (ADR 0012), só no envio; o runner os passa ao processo do agente e não os guarda |
| `gates` | `[{"command", "expect"}]` (até 10, `expect` igual a `pass` ou `fail`): comandos que o runner roda no diretório de trabalho, em ordem, **depois que o agente termina bem**. O `job:finished` traz `gates` com cada um mais `exit_code`, `output` (o fim), `passed` e `duration_ms`. O runner só informa; quem decide é o control plane |
| `setup` | `{"copy"?, "command"?}`: prepara o worktree **quando ele é criado**. O runner clona os caminhos de `copy` do diretório para o worktree (*copy-on-write*: `cp -c` no APFS, `--reflink` no Linux) e depois roda `command` no worktree. Sem `copy`, clona os que encontrar entre `deps`, `_build`, `node_modules`, `.venv`, `venv`, `vendor/bundle` e `target`. Um caminho que o worktree já tem (versionado) fica como está |

O `job:finished` passa a levar `structured_output`, `artifact` e `workdir` (o
diretório real em que o job rodou). Leva também `setup`
(`{"duration_ms", "copied", "command", "exit_code", "output"}`) quando o job criou o
worktree. Se o comando de setup falha, o job falha, e o worktree é removido para que a
próxima tentativa recomece.

Num worktree, o `job:finished` leva ainda `changes`: o que a etapa mudou ali, medido
com git sem tocar no índice nem nos commits do agente. O runner grava a *tree* dos
arquivos (versionados ou não, sem os ignorados nem os copiados pelo setup) no início e
no fim da etapa, e na criação do worktree.

| Campo | Conteúdo |
|---|---|
| `files` | `[{"path", "added", "removed"}]` alterados na etapa; `added` e `removed` são `null` num arquivo binário |
| `patch` | o diff unificado da etapa, cortado numa linha inteira em 200 KB |
| `truncated` | se o patch foi cortado |
| `task_files` | os arquivos alterados desde a criação do worktree, no mesmo formato de `files` | Um diretório que não existe ou que não é a raiz
de um repositório git (para `worktree`) faz o job falhar com o motivo em `error`.

### 4.5 Worktrees

O worktree de uma tarefa fica no runner depois que ela termina, até alguém pedir a
remoção (`PipeMaestroProtocol.Worktree`).

| Evento | Sentido | Payload |
|---|---|---|
| `worktree:remove` | control plane → runner | `{"task_id", "directory"}`: remove o worktree e mantém o branch no repositório. É reenviado a cada join até ser confirmado |
| `worktree:removed` | runner → control plane | `{"task_id", "error"?}`. O runner recusa (`error`) se a tarefa tem job em execução ou na fila |
| `worktree:usage` | runner → control plane | `{"count", "bytes", "free_bytes"}`: quantos worktrees o runner guarda, o espaço que ocupam e o espaço livre no disco. É enviado depois de cada join e a cada cinco minutos, se mudou |

### 4.6 Estados

```
queued ──job:started──► running ──job:finished──► succeeded | failed | canceled
   └──── cancelado antes de começar ──► canceled
```

No join, um job `running` daquele runner que não está em `running_job_ids` vira
`failed`, porque o runner reiniciou e perdeu o processo.

## 5. Versionamento

`protocol_version` aumenta quando muda algo que quebra compatibilidade. O control
plane mantém as versões anteriores em `supported_versions/0` durante a janela de
compatibilidade, e o runner sempre anuncia a versão com que foi compilado.
