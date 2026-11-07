# Plano — Runner reinicia sozinho após a atualização e não perde jobs em quedas ou restarts

Etapa 1 (entendimento e plano). Base: `origin/main` em `da4d4a0`, sem commits de outras tarefas na branch.

## 1. Causa confirmada: por que o runner não volta depois de se atualizar

### O caminho no código

1. O join é recusado com `"outdated"`. `PipeMaestroRunner.Connection.handle_topic_close/3`
   (`apps/pipe_maestro_runner/lib/pipe_maestro_runner/connection.ex`) chama `stop_jobs/1`,
   avisa `{:outdated, refusal}` e para.
2. `Commands.Start.loop/3` chama `Update.handle/2`. `Update.consent/2` escolhe o modo
   **só por `opts[:tty?]`** (`Output.tty?/0`, que lê `:io.getopts(:standard_io)[:terminal]`):
   `:interactive` com TTY e `:service` sem TTY.
3. `SelfUpdate.relaunch/4`:
   - `:service` → `System.halt(0)`. Supõe que launchd (`KeepAlive`) ou systemd
     (`Restart=always`) sobe o binário de novo;
   - `:interactive` → `Port.open` do binário novo como filho (`:nouse_stdio`). O BEAM
     antigo fica vivo esperando o `exit_status`, e `Update.relaunch/3` só então dá
     `System.halt(status)`.
4. `Service.definition/2` não põe nenhuma marca no ambiente: o runner não sabe se está
   sob um gerenciador.

### Reprodução (feita nesta etapa)

Medi `:io.getopts(:standard_io)[:terminal]` com a mesma toolchain do projeto
(Elixir 1.20.4 / OTP 28, `.tool-versions`) em cada forma de execução:

| Forma de execução | `terminal` | Modo escolhido | Resultado depois do `install` |
|---|---|---|---|
| stdin e stdout redirecionados (`</dev/null >log`, como launchd e systemd fazem) | `false` | `:service` | `halt(0)`. Sob o serviço, o gerenciador sobe de novo: **funciona** |
| `nohup pipemaestro start >log 2>&1 &` | `false` | `:service` | `halt(0)` e **ninguém sobe o processo: o runner fica parado** |
| num pty (terminal) | `true` | `:interactive` | o filho assume e o pai fica esperando: **funciona, mas a cadeia cresce** a cada atualização. Se o pai morre, o filho fica órfão |
| num pty com stdout redirecionado (`pipemaestro start \| tee log`, `> log`) | `false` | `:service` | `halt(0)`: **o runner para mesmo estando num terminal** |

**Causa confirmada:** sem TTY, o runner toma "não há terminal" como "estou sob um
gerenciador" e sai com 0. Fora do serviço instalado (nohup, tmux com saída
redirecionada, pipe para `tee`, outro supervisor), ninguém o sobe. Com TTY, ele não
para, mas cada atualização deixa mais um BEAM esperando.

Esta etapa não rodou a reprodução ponta a ponta com o binário Burrito. Ela exige o
binário gerado em Docker (`make runner.binary`) e uma plataforma exigindo outra versão.
O que mostra a causa é o comportamento do OTP medido acima, que é o mesmo da release
Burrito, mais o código de `Update.consent/2` e `SelfUpdate.relaunch/4`. **A etapa de
implementação repete os três cenários (a) terminal, (b) `nohup … &` e (c) `service
install` com o binário Burrito** (`make runner.binary TARGET=macos_arm64` e um servidor
local que exija outra versão do runner) e registra o resultado no PR.

## 2. Entendimento

O que muda para quem usa:

- **O runner atualizado sempre volta sozinho**: no terminal, com `nohup`/tmux/pipe,
  sob launchd ou sob systemd, incluindo serviços instalados antes desta mudança.
- **Um deploy não falha mais jobs.** O runner recusado por versão termina o que está
  rodando (até um prazo), guarda as saídas e só então se atualiza. Depois entrega tudo.
- **Uma queda do runner não gasta tentativas.** Um job perdido por reinício, atualização
  ou crash do runner volta para a fila da mesma etapa, na mesma tentativa e no mesmo
  worktree. Depois de um limite, a tarefa para em `awaiting_decision` com o motivo.
  A linha do tempo mostra "Perdida (runner)", distinta de "Falhou", e os eventos do
  runner mostram `job_lost`.
- **O runner só desiste quando reconectar não ajuda** (token revogado, ou
  `--no-auto-update` sem terminal). Um crash da conexão é reiniciado com backoff, sem
  derrubar os jobs.
- **Depois de um restart do servidor**, os jobs que seguiram rodando continuam `running`.
  A credencial git volta a ser renovada, e um cancelamento pedido enquanto o canal estava
  fora é reenviado.

Os critérios de aceite são os da tarefa. Cada um tem o teste correspondente na §8.

## 3. Decisões (vão para a ADR nova)

### D1. Como reexecutar: sinal explícito, não o TTY

Novo `SelfUpdate.mode/2` (puro, testável) decide a partir de `env` e `tty?`:

| Condição | Modo | O que faz |
|---|---|---|
| `PIPEMAESTRO_SERVICE=1` (gerado por `Service.definition/2`) | `:service` | `halt(0)`; o gerenciador sobe o binário novo |
| sem a marca, mas `XPC_SERVICE_NAME=com.pipemaestro.runner` (launchd) ou `INVOCATION_ID` sem TTY (systemd) | `:service` | idem. **É o caminho dos serviços antigos**, instalados sem a marca |
| `PIPEMAESTRO_RELAUNCH_PARENT=1` (sou filho de um runner que espera) | `:handoff` | sai com o status 75, e o pai sobe o binário novo |
| com TTY | `:interactive` | `Port.open` do binário novo com `:nouse_stdio` e `PIPEMAESTRO_RELAUNCH_PARENT=1` no ambiente do filho. O pai fica num laço: com o status 75 sobe o binário (novo) de novo, com qualquer outro status sai com ele. **A profundidade fica em 2 para sempre**: o pai fixo e o runner da vez. Não há cadeia crescente |
| sem TTY e fora do serviço | `:detached` | sobe o binário novo desacoplado (`/bin/sh -c 'exec 3>&- 4>&-; nohup "$0" "$@" &'`), herdando stdout e stderr (o mesmo log), e sai com `halt(0)` depois de o `sh` confirmar o spawn. O novo processo é adotado pelo init/launchd |

Garantia contra dois runners ao mesmo tempo (no legado e no `:detached`): um **lock de
instância** `runner.pid` em `Config.dir()`. O `start` espera até 30 s o pid anterior
morrer (`kill -0`) antes de conectar. Ao assumir o lock, o processo novo "assume" de
fato, e o antigo já saiu.

Alternativa rejeitada para o terminal: `execve` por NIF. É a única troca verdadeira do
processo no BEAM, mas exige código nativo compilado para cada alvo do Burrito. Sair e
deixar o filho em background tira dele o terminal: o Ctrl+C não chega mais e uma leitura
dá `SIGTTIN`. O pai fixo com o protocolo do status 75 resolve sem código nativo.

`--no-auto-update` mantém o comportamento da ADR 0038: pergunta no terminal e, sem
terminal, sai com a mensagem. É um dos dois casos em que o runner sai de vez.

### D2. Drenar antes de atualizar, sem ficar conectado

Recusado por versão, o runner **não reconecta enquanto drena** (a política de
igualdade da ADR 0023 continua: o runner antigo não fica online). Ele:

1. para de iniciar jobs (`JobRunner.drain/1`: a fila de espera é descartada, porque esses
   jobs seguem `queued` no control plane e voltam no próximo join);
2. espera os jobs em execução terminarem, até o prazo `--drain-timeout` (minutos;
   padrão **30**; variável `PIPEMAESTRO_DRAIN_TIMEOUT_MS` para os testes). A espera é
   **assíncrona**: hoje `stop_jobs/1` dorme dentro do processo da conexão, que por isso
   não recebe os `{:job_out, ...}` dos jobs cancelados;
3. grava a outbox inteira no arquivo (`Outbox.persist_all/1`: inclui `job:event` e
   `job:started`, não só os duráveis), para entregar depois do reinício. O control plane
   ignora o repetido (`seq`, `not_queued`);
4. registra `update_draining` no log (com o número de jobs e o prazo) e só então chama
   `Update.handle/2`.

Se o prazo vence, os jobs restantes são parados como hoje, mas **sem mandar o
`job:finished` cancelado** (`JobRunner.cancel(pid, id, :lost)`, que não reporta o fim).
Eles faltam em `running_job_ids` no próximo join, e o control plane os trata como perda
por infraestrutura (D3).

Prazo padrão de 30 min: cobre a maioria das etapas e fica abaixo da validade das
credenciais git renovadas (ADR 0037). Durante a drenagem não há renovação, e o risco
está nos riscos (§10).

### D3. Perda por infraestrutura não é tentativa

- No join, `Jobs.reconcile/2` separa os jobs perdidos:
  - **job de etapa** (`stage_run_id`): o job vira `failed` com
    `error: "Perdido: o runner reiniciou durante a execução."` e vai para
    `Tasks.job_lost/1`, **não para o gate**. O `StageRun` vira `:lost`, e um `StageRun`
    novo é criado com o **mesmo `attempt`**, `requeue + 1`, as mesmas `instructions` e
    `answers` e o mesmo `feedback`. O job novo vai para o mesmo runner e o mesmo
    worktree, pelo `job_context` da tarefa;
  - jobs avulsos, propostas e análises: ficam `failed` como hoje (fora do escopo).
- Limite: **3 perdas por tentativa de etapa** (`config :pipe_maestro, :max_lost_requeues`).
  Ao atingi-lo: `awaiting_decision` com "A etapa "X" foi interrompida N vezes por queda
  ou reinício do runner.", **sem análise de falha** (o agente não errou).
- Um `job:finished` com `status: "canceled"` de um job sem `cancel_requested_at` (um
  runner antigo que cancelou por conta própria ao ser recusado) também é tratado como
  perda, não como cancelamento da tarefa.
- Cada perda grava `RunnerTelemetry.record_event(runner, "job_lost", "warning", ...)` com
  `job_id` e `task_id` (grupo `connection`).

### D4. Conexão supervisionada

A árvore do `start` vira `PipeMaestroRunner.Session` (Supervisor, `:one_for_one`):

- `PipeMaestroRunner.Outbox.Server` (nomeado): dono da `Outbox` e do arquivo. É o destino
  dos `{:job_out, ...}` do `JobRunner` e dos lotes do `LogCollector`. Encaminha à conexão
  registrada e recebe dela `sent`/`confirmed`. Sobrevive ao crash da conexão, sem perder
  `job:event` em memória.
- `PipeMaestroRunner.JobRunner` (nomeado, `owner: Outbox.Server`). Os `{:job_live, ...}`
  vão por ele e são descartados sem conexão, como hoje.
- `PipeMaestroRunner.Connection.Keeper`: inicia a `Connection`, monitora e a reinicia
  com backoff (500 ms … 30 s, o mesmo de `Connection.backoff/0`), sem limite de tentativas.
  Repassa ao `Commands.Start` só os eventos terminais (`:rejected`, `{:outdated, _}`
  depois da drenagem) e os informativos.

`Connection` deixa de iniciar o `JobRunner` e passa a recebê-lo por opção.
`handle_disconnect/2` com `{:error, _}` de `reconnect/1` para a conexão, e o Keeper sobe
outra. `Commands.Start.loop/3` monitora a `Session`, não a `Connection`: o
`{:DOWN, ...}` da conexão deixa de chamar `Output.fail!`.

### D5. Restart do servidor

Já funciona: o backoff, a outbox reenviada a cada join, os `queued` reenviados por
`Jobs.reconcile/2` e o `seq` deduplicado. Falta:

- **renovação da credencial git**: o `Process.send_after({:renew_credential, id})` vive no
  processo do canal e some com ele. No `after_join`, para cada job `running` do runner que
  está em `running_job_ids` e tem credencial (`Runners.capable?(runner, "git_credential")`),
  o canal manda **já** uma credencial nova (`job:credential`) e agenda a próxima
  renovação (`schedule_renewal/2`). Não dá para saber quanto tempo o servidor ficou fora;
- **cancelamento pedido com o canal fora**: `Jobs.cancel` só faz broadcast. No
  `after_join`, um job `running` com `cancel_requested_at` recebe `job:cancel` de novo.
- Nada mais vive só em memória: pedidos de diagnóstico são efêmeros, remoções de
  worktree já são reenviadas (`Tasks.pending_worktree_removals/1`) e o estado online vem
  do `RunnerStatus.track`.

## 4. Mudanças por app

### `apps/pipe_maestro_runner`

- `self_update.ex`: `mode/2`; `relaunch/4` para `:service`, `:handoff`, `:interactive`
  (laço do pai com o status 75) e `:detached`; constantes `@handoff_status 75` e as
  variáveis `PIPEMAESTRO_SERVICE`/`PIPEMAESTRO_RELAUNCH_PARENT`.
- `update.ex`: `consent/2` devolve só o consentimento, e o modo vem de `SelfUpdate.mode/2`;
  os marcadores `update_applied`/`update_failed` continuam iguais.
- `service.ex`: `PIPEMAESTRO_SERVICE=1` no plist (`EnvironmentVariables`) e no unit
  (`Environment=PIPEMAESTRO_SERVICE=1`).
- `connection.ex`: drenagem assíncrona no lugar de `stop_jobs/1`; recebe `:job_runner` e
  `:outbox` (servidor) por opção; `restart: :temporary` fica, quem reinicia é o Keeper.
- `connection/keeper.ex` (novo), `outbox/server.ex` (novo), `session.ex` (novo).
- `job_runner.ex`: `drain/1` (não inicia nada da fila e descarta a espera),
  `cancel/3` com `:lost` (para o processo sem reportar o fim) e `owner` aceita um nome.
- `outbox.ex`: `persist_all/1`.
- `commands/start.ex`: lock de instância, `--drain-timeout`, supervisão pela `Session`,
  e o `{:DOWN, ...}` só da `Session`. A `@moduledoc` muda de acordo.
- `log_collector.ex`: sem mudança de contrato (o `attach/2` já é por pid a cada join).

### `apps/pipe_maestro` (domínio)

- `jobs.ex`: `reconcile/2` encaminha os perdidos de etapa para `Tasks.job_lost/1` e
  devolve `{queued, still_running}`, ou uma função nova `running_among/2` para o canal.
  O `finish` trata o `canceled` sem `cancel_requested_at` como perda.
- `tasks.ex`: `job_lost/1`. `start_stage` ganha `requeue` e `feedback` explícitos.
  `previous_feedback`, `latest_run`, `last_attempt`, `attempts_query` e as consultas
  ordenadas por `attempt` passam a desempatar por `requeue` e a ignorar `:lost` onde
  procuram a última tentativa válida.
- `tasks/stage_run.ex`: status `:lost`; campo `requeue` (inteiro, padrão 0).
- Migração nova: `alter table(:stage_runs) add :requeue, :integer, null: false, default: 0`.
  O `status` já é `:string`, e `:lost` não pede migração. O índice
  `[:task_id, :index, :attempt]` continua (não é único).
- `runner_telemetry/event.ex`: `"job_lost" => "connection"`.

### `apps/pipe_maestro_web`

- `channels/runner_channel.ex`: `after_join` com a credencial renovada na hora mais o
  agendamento, e o `job:cancel` reenviado (D5).
- `components/task_components.ex`: `stage_label(:lost)` → `{"Perdida (runner)", "warning"}`.
- `live/task_live/show.ex`: os `data-testid` das tentativas ganham o sufixo `-r<requeue>`
  quando `requeue > 0`, porque o par `key`+`attempt` deixa de ser único. A tentativa
  perdida mostra o motivo (`run.error`) com `data-testid="stage-run-lost-<key>-<attempt>"`.
- A tela de eventos do runner (ADR 0039) lista `job_lost` pelo mecanismo genérico de
  grupos, sem tela nova.

### `apps/pipe_maestro_protocol`

- `runner_log.ex`: `update_draining` entra na lista fechada `@events`. A mudança é aditiva.
- `Hello`, `Job`, `JobEvent` e os tópicos não mudam.

## 5. Fronteiras

- O runner continua dependendo só de `protocol`. Os módulos novos (`Session`, `Keeper`,
  `Outbox.Server`) são OTP puro, sem Phoenix nem Ecto.
- O domínio não chama a web: `Tasks.job_lost/1` e `RunnerTelemetry.record_event/5` ficam
  em `pipe_maestro`, e o canal só os chama.
- `protocol` não ganha dependência.

## 6. Protocolo

- **Formato das mensagens:** nenhum campo muda. Só a lista fechada de `event` do
  `runner:log` ganha `update_draining`.
- **`protocol_version` não sobe** (fica 4): a mudança é aditiva e o control plane aceita
  um `event` novo na lista.
- **Semântica que muda e vai para `docs/specs/protocolo-runner.md`:**
  - §3: recusado por versão, o runner drena (para de iniciar, termina os jobs até o prazo,
    persiste a outbox) em vez de cancelar, e depois se atualiza;
  - §4.2: a outbox persiste os duráveis sempre e tudo antes de uma atualização. O trecho
    "A outbox vive em memória: se o runner reinicia, ela se perde" já está errado hoje e
    sai;
  - §4.1/§4.2: depois de cada join, o control plane renova já a credencial dos jobs que
    seguem rodando e reenvia `job:cancel` dos pedidos pendentes;
  - §4.6: um job `running` ausente de `running_job_ids` é **perdido por
    infraestrutura**: o job vira `failed`, e a etapa é reenfileirada sem gastar tentativa.
    Um `canceled` sem pedido de cancelamento conta igual;
  - §4.7: `update_draining` na lista de eventos.
- **Runner antigo** (sem esta mudança): **compatível**. Ao ser recusado ele cancela e sai
  como hoje. No join seguinte, já atualizado, os jobs perdidos são reenfileirados sem
  gastar tentativa (a melhoria vale para ele também), e um `job:finished` cancelado que
  ele consiga entregar é tratado como perda. O runner antigo que roda num terminal, num
  `nohup` ou como serviço se atualiza pelo código antigo, uma última vez. Daí em diante
  vale D1. O primeiro salto de um runner fora do serviço e sem TTY continua parando
  (o código que decide é o dele). O guia de deploy registra isso como nota de transição.

## 7. Telas

- **Linha do tempo da tarefa** (`TaskLive.Show`): badge "Perdida (runner)" (`<.badge>`
  da Petal, via `stage_run_status`, já usado), motivo da perda e as duas tentativas com
  o mesmo número separadas pelo sufixo `-r<n>` nos test ids.
- **Eventos do runner**: o `job_lost` aparece pelo filtro de grupo existente
  (`connection`). Sem componente novo.
- Playwright: um caso novo em `e2e/tests/task-pipeline.spec.ts` (ou
  `runner-connection.spec.ts`, se o fixture de runner já mata e reinicia o processo). O
  runner do e2e é derrubado com um job em andamento e sobe de novo. A spec confere
  `stage-run-status-<key>-1` = "Perdida (runner)", `stage-run-<key>-1-r1` em andamento,
  e o evento `job_lost` na tela do runner (`runner-telemetry.spec.ts`).
- `make e2e` e `make e2e.shots` (claro e escuro) da tarefa com uma tentativa perdida e
  da lista de eventos do runner.

## 8. Testes por critério

| Critério | Teste |
|---|---|
| Modo de reexecução | `self_update_test.exs`: `mode/2` em cada linha da tabela de D1, incluindo os legados `XPC_SERVICE_NAME` e `INVOCATION_ID`. `relaunch/4` com `:spawn`/`:halt` injetáveis: `:service` dá halt 0; `:detached` dá spawn desacoplado e depois halt; `:handoff` dá halt 75; `:interactive` relança no 75 e sai com outro status. Nenhum caminho termina sem relançar ou sem que um gerenciador relance |
| Arquivo de serviço | `service_test.exs`: o plist e o unit contêm `PIPEMAESTRO_SERVICE=1`. `mode/2` com o ambiente de um serviço antigo dá `:service` |
| Drenagem | `connection_test.exs` (Slipstream `test_mode?` + `claude` falso que demora): recusa `"outdated"` com um job rodando não manda `cancel`. O job termina, o `job:finished` está no `outbox.bin`, e só depois chega `{:outdated, refusal}` ao notify. Outro caso: o prazo vence, o job é parado e **não** fica `job:finished` na outbox |
| Perda sem tentativa | `tasks_test.exs`/`jobs_test.exs`: um job `running` ausente no `reconcile` gera um `StageRun` `:lost` e um novo com o mesmo `attempt`, `requeue: 1` e job `queued` no mesmo runner. O gate não roda. Na quarta perda, a tarefa vai para `awaiting_decision` com o motivo de infraestrutura e sem job de análise. Um `canceled` sem pedido dá perda. O evento `job_lost` é gravado. Uma etapa de grupo perdida também é reenfileirada |
| Crash da conexão | `session_test.exs`/`keeper_test.exs`: `Process.exit(conn, :kill)` com um job rodando. O `JobRunner` e o job seguem vivos, a outbox mantém os eventos, e uma conexão nova faz join depois do backoff. `Start` não sai |
| Restart do servidor | `runner_channel_test.exs`: join com `running_job_ids` contendo um job `running` com credencial. O job continua `running`, chega `job:credential` e uma renovação fica agendada (`renewal_margin_ms` curto, como os testes atuais fazem). Um job com `cancel_requested_at` recebe `job:cancel` |
| Telas | e2e da §7 e `task_live/show_test.exs` (badge e test ids) |
| Gate | `make ci` verde |

## 9. Documentação

- **ADR nova `docs/adr/0041-runner-resiliente-a-reinicios.md`**: D1 a D5. Atualiza em
  parte a ADR 0025 ("Rodar de novo"), a 0038 e a 0023 ("O runner para e explica":
  passa a drenar).
- `docs/specs/protocolo-runner.md`: §3, §4.1, §4.2, §4.6 e §4.7 (ver §6).
- `docs/specs/maquina-de-estados-tarefa.md`: a frase "Um job perdido … conta como
  `failed`" vira uma linha da tabela (perda → tentativa `lost` → reenfileirada na mesma
  tentativa; no limite → `awaiting_decision` sem análise).
- `docs/guias/deploy.md`: nota de transição para runners antigos fora do serviço.
- As `@moduledoc` de `Service`, `Update`, `SelfUpdate`, `Connection` e `Commands.Start`.

## 10. Riscos

- **Migração**: só uma coluna com padrão, sem backfill. Dados existentes ficam
  `requeue = 0`.
- **Consultas por `attempt`**: várias assumem uma linha por `(index, attempt)` (linha do
  tempo compacta, ADR 0017, `previous_feedback`, `latest_run` e o `close_step` dos
  grupos). Todas precisam de desempate por `requeue` e de ignorar `:lost`. É onde mora o
  maior risco de regressão: cobrir com testes de grupo e de redo.
- **Concorrência**: dois runners com o mesmo token (legado mais `:detached`) resolvidos
  pelo lock de instância. O `reconcile` roda no `after_join` de um canal só por runner.
  Um runner que reconecta duas vezes depressa pode chamar `reconcile` duas vezes, então
  `job_lost` checa `stage_run.status == :running` (idempotente, como `job_finished/1`).
- **Credencial durante a drenagem**: sem conexão, nada renova. Um job que entrega depois
  de a credencial vencer falha na entrega, e isso é uma tentativa normal. O prazo padrão
  de 30 min reduz o risco, que fica registrado na ADR.
- **Sinais no terminal**: com o pai fixo, o Ctrl+C chega aos dois BEAMs (mesmo grupo de
  processos), como hoje com a cadeia. Conferir com o binário Burrito na implementação
  que os dois saem.
- **Detecção do systemd antigo**: `INVOCATION_ID` também aparece em processos filhos
  de qualquer serviço, como um `pipemaestro` rodado de um script sob outro unit. Por
  isso só conta junto com a ausência de TTY. No pior caso, o runner sai esperando um
  gerenciador que o reinicia (`Restart=` do outro unit) ou fica parado como hoje. O
  caso é raro, está documentado, e `service install` de novo resolve.
- **Cobertura** (60% por app): os módulos novos do runner são testáveis em processo, sem
  `halt` real (funções injetáveis, como `Update` já faz).
- **Dialyzer**: `relaunch/4` hoje tem `no_return` nos caminhos de halt. Os tipos novos
  (`mode`, a tupla de retorno do `reconcile`) entram com `@spec` desde o início.

## 11. Ordem de implementação (um commit por bloco)

1. Domínio: `StageRun` `:lost`/`requeue`, migração, `Tasks.job_lost/1`, `Jobs.reconcile/2`,
   `canceled` sem pedido e `job_lost` na telemetria, com os testes.
2. Canal: credencial e cancelamento no `after_join`, com os testes.
3. Runner: `Outbox.Server`, `Session`, `Keeper` e o `JobRunner` nomeado, com os testes de
   crash.
4. Runner: drenagem, `cancel/3 :lost`, `persist_all/1`, `update_draining` (protocol),
   com os testes.
5. Runner: `SelfUpdate.mode/2`, os relaunches, a marca no `Service` e o lock de
   instância, com os testes. Depois, a reprodução manual com o binário Burrito.
6. Telas, e2e e shots.
7. ADR 0041, specs e guia. `make ci`.
