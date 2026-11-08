# Protocolo runner ↔ control plane (v4)

> Status: v4, implementada em `apps/pipe_maestro_protocol`, que é a fonte da
> verdade das constantes e dos formatos `Hello`, `Job` e `JobEvent`. Ela cobre login,
> conexão, jobs (seção 4), o contexto das etapas de tarefa (seção 4.4) e a telemetria do
runner (seção 4.7). Leases e
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
    "protocol_version": 4, "runner_version": "2026-11-04.01",
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
O control plane só aceita o runner que está **exatamente na versão de runner que ele
exige** (`PipeMaestro.Runners.version_check/1`,
[ADR 0023](../adr/0023-runner-na-versao-da-plataforma.md),
[ADR 0035](../adr/0035-versao-propria-do-runner.md)). Essa versão é a do último commit que
mudou o runner, não a do control plane, e o deploy publica o runner dela. Qualquer outra
versão, mais velha ou de outro build, recebe `409`. O `"version"` é a versão de runner
exigida:

```json
{"error": "outdated", "reason": "outdated", "version": "dev+6f85389",
 "runner_version": "dev+fdafa32",
 "download_url": "https://pipemaestro.app/downloads/runner/"}
```

O runner não pede o código. O `download_url` é um diretório com um binário por alvo,
`pipemaestro_<alvo>` (`macos_arm64`, `macos_x86_64`, `linux_x86_64`, `linux_arm64`), e
um `SHA256SUMS` no formato do `sha256sum` (`PipeMaestroProtocol.Downloads`). O binário
único oferece baixar e instalar a versão que a plataforma pede
([ADR 0025](../adr/0025-atualizacao-automatica-do-runner.md)), e só baixa se:

- o `download_url` estiver na mesma origem (esquema, host e porta) da plataforma;
- o esquema for `https` (`http` só para `localhost`, `127.0.0.1` e `::1`);
- o SHA-256 do binário baixado conferir com o do `SHA256SUMS`.

Ele troca o executável por `rename` de um temporário no mesmo diretório, e roda o mesmo
comando de novo. Por padrão, sem perguntar; com `--no-auto-update`, pergunta no terminal
([ADR 0038](../adr/0038-atualizacao-automatica-por-padrao.md)). Fora disso (sob Mix, ou
com `--no-auto-update` sem terminal ou recusando a pergunta), mostra as duas versões e o
link, e sai.

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
`ws(s)://<plataforma>/runner/socket/websocket?token=<runner_token>&protocol_version=4`.

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
    runner) ou `login` (o login da máquina);
  - `capabilities` (opcional): o que o runner suporta além da versão do protocolo
    (vazio se omitido). Hoje, `"scratch"`: roda um job num worktree descartável (§4.4); e
    `"git_credential"`: recebe a credencial git do job e a renovação dela (§4.4);
    `"resume_session"`: guarda a sessão do CLI de um job e a retoma num job seguinte
    (`persist_session`, `resume_session_id`, §4.4);
    `"health"`, `"logs"` e `"doctor"`: envia a saúde, o log e o diagnóstico (§4.7);
    `"files"`: dá a cada job a pasta `CP_FILES_DIR` e sobe o que o agente deixa nela
    (§4.8).
    O control plane só oferece uma funcionalidade a quem a anuncia, o que permite
    acrescentar campos ao job sem quebrar runners antigos.

  O runner manda um `Hello` novo a cada (re)join. A resposta é
  `{"runner_id", "name", "workspace", "telemetry"}`, onde `telemetry` é `{"logs"}`:
  `false` quando o workspace não guarda o log dos runners, e então o runner só envia
  as linhas que são eventos (§4.7). Um runner antigo ignora o campo. Entrar no tópico de outro runner dá
  `{"reason": "unauthorized"}`, e um `Hello` inválido dá `{"reason": "invalid_hello"}`.
  Um runner fora da versão de runner que o control plane exige recebe o mesmo payload do `409` do login
  (`{"reason": "outdated", "version", "runner_version", "download_url"}`). Nada dele é
  gravado e ele não fica online. O runner não tenta de novo: para de iniciar jobs,
  espera os que roda terminarem (até `--drain-timeout`, 30 min por padrão), grava a
  outbox inteira no arquivo e só então se atualiza ou pede para baixar a versão atual,
  como no login. Os jobs que passarem do prazo são parados sem reportar o fim e contam
  como perdidos (§4.6) ([ADR 0043](../adr/0043-runner-resiliente-a-reinicios.md)). Como o deploy reinicia o control plane, todo runner
  reconecta e passa por essa checagem. Um deploy que não muda o runner não muda a versão
  exigida, e os runners voltam online.
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
| `job:credential` | `{"job_id", "git_credential"}` | a credencial git renovada de um job na fila ou em execução, alguns minutos antes de a anterior vencer; o runner regrava o arquivo dela (ADR 0037) |

No join, o control plane reenvia `job:assign` para cada job ainda `queued` daquele
runner. Para cada job `running` que o runner diz seguir rodando, manda já um
`job:credential` novo (se o runner anuncia `"git_credential"`) e agenda a próxima
renovação, e reenvia `job:cancel` quando o cancelamento foi pedido com o canal fora.

### 4.2 Runner → control plane

Cada mensagem recebe uma resposta: `ok`, ou `error` com `{"reason"}`, onde `reason`
é `not_found`, `not_queued`, `finished`, `invalid` ou `unknown_message`.

| Evento | Payload |
|---|---|
| `job:started` | `{"job_id"}` |
| `job:event` | `{"job_id", "seq", "type", "data"}`, com `seq` contando a partir de 1 |
| `job:finished` | `{"job_id", "status", "exit_code", "result", "cost_usd", "duration_ms", "num_turns", "files_failed"?, "error"?}`, com `status` igual a `succeeded`, `failed` ou `canceled`. `files_failed` só vem quando é maior que zero: quantos arquivos de `CP_FILES_DIR` não chegaram à plataforma (§4.8) |
| `job:delta` | `{"job_id", "text"}`: o que o agente está escrevendo (até 4 KB do fim), no máximo a cada 250 ms. Sem resposta, fora da outbox e não guardado |
| `job:telemetry` | `{"job_id", "records"}`: até 200 registros `{"name", "at", "attrs"}` da telemetria OpenTelemetry do CLI (`PipeMaestroProtocol.Telemetry`, ADR 0015). Pode chegar depois do `job:finished`; a outbox o descarta primeiro, como os eventos, quando enche |

Para a auditoria (ADR 0015), o `job:finished` também traz o que a execução contou de
si:

- `session_id`, `cli_version`, `model`, `stop_reason` e `result_subtype`;
- `session_resumed`, só num job que pediu `resume_session_id`: `true` quando o agente
  retomou a sessão, `false` quando o CLI não a tinha e o job rodou do zero;
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
`job:finished` repetido responde `not_queued` ou `finished`. Um job cujo `job:finished`
ainda não foi confirmado entra em `running_job_ids` do `Hello`, para que a
reconciliação não o falhe antes do reenvio. Só o início ou os eventos pendentes não
bastam: um job parado como perdido na drenagem tem só esses, e precisa faltar no
`Hello` para contar como perda. O `job:finished` e o `worktree:removed` também ficam num
arquivo e sobrevivem a um reinício do runner; antes de uma atualização, a outbox
inteira vai para o arquivo. Um crash da conexão não a perde: ela vive num processo
próprio, e só a conexão é reiniciada.

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
| `model`, `max_budget_usd` | passados em `--model` e `--max-budget-usd`. `max_budget_usd` só vem quando a pessoa configurou um teto na etapa; sem ele, o runner não passa a flag |
| `artifact_path` | caminho relativo onde o agente escreve o artefato da etapa; vai na env `CP_ARTIFACT_PATH`, e o runner devolve o conteúdo (até 64 KB). Sem o campo, o runner tira `CP_ARTIFACT_PATH` do ambiente do agente, para que um valor herdado não vaze para o job. Em qualquer job, um runner com a capacidade `"files"` também passa `CP_FILES_DIR`, o caminho absoluto da pasta do job fora do worktree (§4.8). `CP_FILES_DIR` é reservada: um segredo não a sobrescreve |
| `timeout_ms` | tempo máximo do agente; ao estourar, o runner encerra o grupo de processos e o job falha |
| `system_prompt`, `mcp_config`, `agents`, `agent` | o contexto do pipeline e o agente da etapa (ADR 0011): vão em `--append-system-prompt`, `--mcp-config`, `--agents` e `--agent` |
| `delivery` | `{"push"?, "pr"?, "issue_comment"?}`: o que o runner faz com a etapa que passou nas verificações e nos gates ([ADR 0033](../adr/0033-contrato-entre-harness-e-agente.md)). O runner **não faz commit**: faz o push do `HEAD` (já verificado), abre ou adota o PR da branch e escreve só o bloco da plataforma na descrição (`{"title", "block", "ready"}`: o título só na criação; `ready` tira o prefixo de rascunho) e comenta na issue (`{"url", "body"}`) e, com `"status"` (`{"context", "state", "description", "target_url"}`), põe o commit status da etapa no que empurrou, num Forgejo. Numa tarefa de um repositório vinculado cuja conexão deixa a plataforma chamar o host ([ADR 0036](../adr/0036-integracoes-com-hosts-git.md)), a entrega é só `{"push": true}`: o PR e a issue ficam com o control plane. O bloco do PR é o de `PipeMaestroProtocol.PrText`. O `job:finished` traz `delivery` com `{"commit", "pushed", "pr_url", "commented", "error"?}`, `commit` sendo o commit entregue |
| `checks` | `[{"id", ...}]`: as verificações da plataforma, rodadas depois do agente e antes dos gates (ADR 0033): `branch` (`branch`), `no_operation`, `contains_origin` (`branch`), `clean` (`artifacts`: a pasta dos artefatos, que fica de fora, como o que o setup copiou ou criou), `artifact_committed` (`path`), `no_artifacts` (`path`) e `no_secrets` (os valores de `env`, nunca escritos no resultado). Cada resultado vem em `gates`, com `"platform": true`, `"id"` e `"message"` (o motivo, escrito para o agente). Com alguma falhando, os gates não rodam e não há entrega |
| `sync` | `true` numa etapa de tarefa com git: antes do agente, o runner faz o `fetch` da branch, o fast-forward quando ele é seguro (na branch, limpo, nada em andamento, só atrás) e, fora isso, anexa ao prompt a seção "Estado do repositório" com o que achou |
| `artifacts` | `[{"path", "content"}]`: os artefatos das etapas anteriores, como o control plane os guardou. Antes do agente, o runner grava os que faltam no disco |
| `git_credential` | `{"host", "username", "password", "expires_at"?}`: a credencial do repositório vinculado da tarefa ([ADR 0037](../adr/0037-credencial-git-por-job.md)). O runner a grava em `<workdir>/credentials/<job_id>` (`0600`) e a entrega ao git, o seu e o do agente, por um credential helper configurado em variáveis `GIT_CONFIG_*`, nunca na URL do remoto; o arquivo sai quando o job termina. A senha entra na verificação `no_secrets`. Só vai a um runner com a capacidade `"git_credential"`, e nunca numa proposta |
| `scratch` | `true` numa análise (ADR 0021): roda num worktree descartável do `directory`, em `<workdir>/scratch/<job_id>`, destacado no `HEAD` (`git worktree add --detach`) e removido quando o job termina. Recebe só a cópia de dependências do `setup`, sem comando, e não reporta `changes`. Exige `directory` e não aceita `worktree` nem `delivery`. O control plane só manda `scratch` a um runner que anunciou a capacidade `"scratch"` no `Hello`: um runner antigo descartaria o campo e rodaria no próprio diretório |
| `persist_session` | `true` quando a etapa seguinte continua esta: o CLI guarda a sessão do job na máquina do runner (sem `--no-session-persistence`), e o `session_id` do `job:finished` a identifica ([ADR 0041](../adr/0041-continuar-a-sessao-da-etapa-anterior.md)). Só vai a um runner com a capacidade `"resume_session"` |
| `resume_session_id` | o `session_id` (1 a 100 bytes: letras, números, `-` e `_`) da etapa anterior, que o agente continua (`--resume <id> --fork-session`), com o prompt deste job como a próxima mensagem. Se o CLI termina com erro antes de abrir sessão alguma (ele não tem aquela sessão), o runner roda o job de novo, uma vez, do zero, no mesmo lugar, e o `job:finished` traz `session_resumed: false`. Não aceita `scratch`. Só vai a um runner com a capacidade `"resume_session"`; um runner antigo ignora o campo e roda do zero |
| `parallel` | `true` numa etapa de um grupo (ADR 0014): roda junto com as irmãs no worktree da tarefa, sem esperar por elas |
| `env` | `{"NOME": "valor"}`: os segredos do workspace (ADR 0012), só no envio; o runner os passa ao processo do agente e não os guarda |
| `gates` | `[{"command", "expect"}]` (até 10, `expect` igual a `pass` ou `fail`): comandos que o runner roda no diretório de trabalho, em ordem, **depois que o agente termina bem**. O `job:finished` traz `gates` com cada um mais `exit_code`, `output` (o fim), `passed` e `duration_ms`. Um gate que já passou na mesma árvore do diretório de trabalho não roda de novo: vem com `"cached": true`, `duration_ms` 0 e o `output` dizendo quando passou ([ADR 0046](../adr/0046-verificacao-por-arvore.md)). O campo é opcional, e um control plane que não o conhece só lê o resultado. O runner só informa; quem decide é o control plane |
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
| `task_files` | os arquivos alterados desde a criação do worktree, no mesmo formato de `files` |

Um diretório que não existe, ou que não é a raiz de um repositório git (para `worktree`
e `scratch`), faz o job falhar com o motivo em `error`.

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
`failed`, porque o runner reiniciou e perdeu o processo. Se é o job de uma etapa, é uma
**perda por infraestrutura**: a etapa roda de novo na mesma tentativa, sem gastá-la, até
um limite, e o runner registra o evento `job_lost`. Um `job:finished` `canceled` de um
job sem pedido de cancelamento conta igual
([ADR 0043](../adr/0043-runner-resiliente-a-reinicios.md)).

### 4.7 Telemetria do runner

A saúde, o log e o diagnóstico do próprio runner
([ADR 0039](../adr/0039-telemetria-do-runner.md)). Só um runner que anuncia `health`,
`logs` ou `doctor` envia a mensagem correspondente, e o control plane só pede o
diagnóstico a quem anuncia `doctor`.

| Evento | Sentido | Payload |
|---|---|---|
| `runner:health` | runner → control plane | `{"at", "cpu_pct", "load1", "mem_used_bytes", "mem_total_bytes", "disk_free_bytes", "disk_total_bytes", "outbox_pending", "running_jobs", "beam_bytes"}` (`PipeMaestroProtocol.RunnerHealth`). Cada número pode ser `null` quando a máquina não o informa. Enviado depois de cada join e a cada 60 s, fora da outbox |
| `runner:log` | runner → control plane | `{"lines"}`: até 200 linhas `{"at", "level", "message", "event"?, "attrs"?}` (`PipeMaestroProtocol.RunnerLog`), `level` igual a `debug`, `info`, `warning` ou `error`, `message` de até 4 KB, já com os segredos redigidos. `event` vem de uma lista fechada (`update_draining`, `update_applied`, `update_failed`, `scratch_remove_failed`, `outbox_dropped`, `connection_lost`, `log_dropped`), com `attrs` de valores simples. Um lote sai a cada 5 s ou 200 linhas, e o runner envia no máximo 1 000 linhas por minuto. Passa pela outbox, que o descarta primeiro, como `job:event`, quando enche. Com `"logs": false` na resposta do join, só as linhas com `event` são enviadas |
| `runner:doctor` | control plane → runner | `{"request_id"}`: roda o diagnóstico agora |
| `runner:doctor` | runner → control plane | `{"request_id"?, "at", "checks"}`: `checks` é `[{"key", "name", "status", "detail"}]` (`PipeMaestroProtocol.RunnerDoctor`), `status` igual a `ok`, `warning` ou `error`. Enviado depois de cada join, a cada hora e em resposta a um pedido, com o `request_id` dele. Fora da outbox |

As respostas são as da §4.2 (`ok`, ou `error` com `invalid`).

### 4.8 Arquivos do job

Os arquivos que o agente deixa para a pessoa ver (screenshots, relatórios, CSVs),
`PipeMaestroProtocol.JobFiles` ([ADR 0042](../adr/0042-arquivos-gerados-pela-etapa.md)).
Só um runner com a capacidade `"files"` os envia, e o control plane só cita
`CP_FILES_DIR` no prompt dos jobs dele.

- **A pasta.** Cada job tem `<workdir>/files/<job_id>`, fora de qualquer worktree, na
  env `CP_FILES_DIR`. Ela é apagada depois do `job:finished` e quando o runner inicia.
- **O envio.** Quando o agente termina (job `succeeded`, `failed` ou `canceled`),
  depois dos checks, dos gates e da entrega e antes do `job:finished`, o runner envia
  cada arquivo regular da pasta, subpastas incluídas, numa requisição própria, fora do
  canal:

  ```
  PUT /api/runner/jobs/<job_id>/files?path=<caminho relativo>
  Authorization: Bearer cpr_…
  Content-Type: application/octet-stream

  <conteúdo do arquivo>
  ```

- **O que não sobe.** Symlinks não são seguidos. Também não sobe um arquivo cujo
  caminho traz o valor de um segredo do job (`env`) nem um que passe dos limites:
  10 MiB por arquivo, 50 MiB e 100 arquivos por job. O caminho é relativo, sem `..`,
  `.`, `\`, NUL nem segmento vazio, e tem até 255 bytes.
- **As respostas.**

  | Status | Corpo | Quando |
  |---|---|---|
  | `201` | `{"path", "byte_size", "sha256", "content_type"}` | guardado; reenviar o mesmo caminho substitui o arquivo |
  | `401` | `{"error": "unauthorized"}` | sem token, ou com token inválido ou revogado |
  | `404` | `{"error": "not_found"}` | o job não existe ou é de outro runner |
  | `413` | `{"error": "too_large", "limit"}` | passou do limite do arquivo ou do job |
  | `415` | `{"error": "unsupported"}` | o corpo não é `application/octet-stream` |
  | `422` | `{"error": "invalid_path"}` | o caminho foi recusado |

- **As tentativas.** Em erro de rede e 5xx, o runner faz até 3 tentativas, com espera
  de 0,5 s, 1 s e 2 s. Ele não repete um 4xx. O que não subiu, somado ao que foi
  pulado, vai em `files_failed` do `job:finished`. Um control plane sem o endpoint
  responde 404, e o job termina como terminaria.
- **O proxy.** Um proxy na frente do control plane precisa aceitar corpos de até
  10 MiB, como o `client_max_body_size 12m;` do nginx em `docs/guias/instalacao.md`.

## 5. Versionamento

`protocol_version` aumenta quando muda algo que quebra compatibilidade. O control
plane mantém as versões anteriores em `supported_versions/0` durante a janela de
compatibilidade, e o runner sempre anuncia a versão com que foi compilado.
