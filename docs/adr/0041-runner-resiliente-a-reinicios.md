# 0041 — Runner resiliente a reinícios e à atualização

- **Status:** aceita
- **Data:** 07/11/2026
- **Altera:** [ADR 0023](0023-runner-na-versao-da-plataforma.md) (o runner recusado
  drena em vez de cancelar), [ADR 0025](0025-atualizacao-automatica-do-runner.md) e
  [ADR 0038](0038-atualizacao-automatica-por-padrao.md) (como o binário novo é
  executado)

## Contexto

Recusado por versão, o runner cancelava os jobs, baixava o binário novo e escolhia como
rodá-lo só pelo TTY: sem terminal, saía com 0 esperando um gerenciador de serviços; com
terminal, subia o binário novo como filho e ficava esperando. Fora do serviço instalado
(`nohup`, tmux com a saída redirecionada, um pipe para `tee`, outro supervisor) ninguém
o subia de novo. No terminal, cada atualização deixava mais um BEAM esperando.

Cada deploy que mudava o runner falhava os jobs em andamento, e um job perdido por queda
do runner contava como tentativa falha da etapa. Um crash da conexão derrubava o
`start` inteiro. Depois de um restart do servidor, a renovação da credencial git e um
cancelamento pedido com o canal fora se perdiam, porque viviam no processo do canal.

## Decisão

### D1. Reexecutar por sinal explícito, não pelo TTY

`SelfUpdate.mode/2` decide pelo ambiente:

| Condição | Modo | O que faz |
|---|---|---|
| `PIPEMAESTRO_SERVICE=1` (gravado por `service install`) | `:service` | sai com 0; o gerenciador sobe o binário novo |
| sem a marca, `XPC_SERVICE_NAME=com.pipemaestro.runner` (launchd) ou `INVOCATION_ID` sem TTY (systemd) | `:service` | idem: os serviços instalados antes desta decisão |
| `PIPEMAESTRO_RELAUNCH_PARENT=1` | `:handoff` | sai com 75, e o runner que o subiu roda o binário novo |
| com TTY | `:interactive` | sobe o binário novo como filho, com `PIPEMAESTRO_RELAUNCH_PARENT=1`. Com 75, sobe de novo; com outro status, sai com ele. São sempre dois BEAMs: o pai fixo e o runner da vez |
| sem TTY e fora de um serviço | `:detached` | sobe o binário novo desacoplado (`nohup … &`, mesma saída) e sai com 0 |

Um lock de instância (`runner.pid` no diretório de configuração) impede dois runners com
a mesma configuração: o `start` espera até 30 s o anterior sair antes de conectar.

`--no-auto-update` mantém a ADR 0038: pergunta no terminal e, sem terminal, sai.

Rejeitado: `execve` por NIF, que exigiria código nativo para cada alvo do Burrito; e
deixar o filho em background, que tira dele o terminal (Ctrl+C, `SIGTTIN`).

### D2. Drenar antes de atualizar

Recusado por versão, o runner não reconecta (a igualdade de versão da ADR 0023 segue).
Ele para de iniciar jobs, espera os que rodam terminarem até `--drain-timeout` minutos
(30 por padrão), grava a outbox inteira no arquivo e registra `update_draining` no log.
Só então se atualiza, e o runner novo entrega o que ficou. Se o prazo vence, os jobs
restantes são parados sem reportar o fim e contam como perdidos (D3). Por isso o
`Hello` só conta como rodando o job cujo `job:finished` está pendente na outbox, não
qualquer job com mensagens pendentes.

Durante a drenagem não há conexão, então a credencial git não é renovada: um job que
entrega depois de ela vencer falha na entrega, como uma tentativa normal. O prazo
padrão fica abaixo da validade da credencial ([ADR 0037](0037-credencial-git-por-job.md)).

### D3. Perda por infraestrutura não gasta tentativa

No join, um job de etapa `running` ausente de `running_job_ids` vira `failed` com o
motivo da perda e vai para `Tasks.job_lost/1`, não para o gate. A tentativa vira `lost`
("Perdida (runner)" na tela) e uma nova é criada com o **mesmo número**, `requeue + 1`,
as mesmas instruções, respostas e feedback, no mesmo runner e worktree. Depois de
`max_lost_requeues` perdas (3) na mesma tentativa, a tarefa vai para
`awaiting_decision` com o motivo, sem análise de falha. Um `job:finished` `canceled`
sem pedido de cancelamento (runner antigo que cancelou por conta própria) conta como
perda. Cada perda vira o evento `job_lost` do runner.

Jobs avulsos, propostas e análises seguem virando `failed`.

### D4. Conexão supervisionada

O `start` roda uma `Session` (supervisor) com o `Outbox.Server`, dono da outbox e do
arquivo, o `JobRunner` e o `Connection.Keeper`, que reinicia a conexão com backoff, sem
limite. Um crash da conexão não derruba os jobs nem a outbox. O runner só sai de vez com
o token revogado ou com `--no-auto-update` sem terminal.

### D5. Restart do servidor

Depois de cada join, o canal manda já uma credencial nova aos jobs que seguem rodando e
agenda a próxima renovação, e reenvia `job:cancel` aos jobs com cancelamento pedido.

## Consequências

- `StageRun` ganha o status `lost` e o campo `requeue`. As consultas da última
  tentativa desempatam por `requeue` e ignoram as perdidas.
- O protocolo não muda de versão: `update_draining` entra na lista de eventos do
  `runner:log`, e o resto é semântica ([protocolo](../specs/protocolo-runner.md)).
- Runner antigo: compatível. Ao ser recusado ele cancela e sai pelo código antigo, uma
  última vez; fora do serviço e sem TTY, esse primeiro salto ainda para
  ([guia de deploy](../guias/deploy.md)). Os jobs que ele perder já voltam sem gastar
  tentativa.
- `INVOCATION_ID` também aparece em filhos de outros units do systemd. Só conta sem TTY;
  no pior caso o runner sai esperando um gerenciador, como antes, e `service install`
  resolve.
