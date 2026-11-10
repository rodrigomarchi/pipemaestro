# 0039 — Telemetria do runner

- **Status:** aceita
- **Data:** 06/11/2026
- **Plano:** [`05-telemetria-do-runner.md`](../plano/05-telemetria-do-runner.md)
- **Relacionadas:** [ADR 0015](0015-auditoria-da-execucao.md), [ADR 0024](0024-resumo-da-execucao-e-metricas-do-agente.md), [ADR 0025](0025-atualizacao-automatica-do-runner.md)

## Contexto

A telemetria do agente (o que o `claude` faz num job) chega completa ao control plane. A
do runner não:

- do runner, o control plane guarda só o último `Hello`, o uso dos worktrees e o último
  connect e "visto";
- o `terminate/2` do canal descarta o motivo da queda, e um join recusado não deixa
  rastro;
- o log do runner é o stdout redirecionado pelo launchd/systemd para o `runner.log`, na
  máquina. Falhas fora do agente aparecem num campo do `job:finished`, ou em lugar
  nenhum;
- o `doctor` só roda na máquina.

## Decisões

1. **Aditivo, sem subir `protocol_version`.**
   - O runner anuncia as capacidades `health`, `logs` e `doctor` no `Hello`. O control
     plane só pede o doctor a quem anuncia `doctor`.
   - A página de um runner sem elas diz que é preciso atualizá-lo para ver a telemetria.
   - Um control plane antigo responde `unknown_message`, o que já encerra a mensagem na
     outbox.
2. **Conexões são observadas pelo control plane, sem protocolo.**
   - Cada join aceito abre uma sessão (`runner_sessions`). O `terminate/2` a fecha com o
     motivo:
     - `closed`: a conexão terminou;
     - `revoked`: o runner foi revogado;
     - `crashed`: o canal caiu com erro;
     - `reconnected`: um join novo achou a sessão ainda aberta.
   - Um join recusado vira uma sessão de duração zero com `outdated` ou `invalid_hello`.
   - No boot, as sessões que ficaram abertas por um restart do control plane são fechadas
     com `restart`, na hora do último "visto".
   - O uptime de um período é a soma das sessões dentro dele.
   - O motivo que o runner viu (a rede caiu, recusa) chega pelo log, como evento
     `connection_lost`.
3. **Saúde por amostra a cada 60 s** (`runner:health`).
   - Campos: CPU (%), load de 1 min, memória usada e total, disco livre e total da raiz de
     trabalho, mensagens pendentes na outbox, jobs em execução e memória da VM do runner.
     Um campo que a máquina não informa vai `null`.
   - A coleta usa comandos do sistema, como o `disk.ex`, sem `:os_mon`, para não mexer na
     release do Burrito:
     - macOS: `sysctl`, `vm_stat` e `ps`;
     - Linux: `/proc/loadavg`, `/proc/meminfo` e `/proc/stat`.
   - A amostra não passa pela outbox. Uma lacuna no gráfico é a própria informação de que
     o runner estava fora.
   - As amostras ficam 7 dias, e os gráficos agregam no SQL.
4. **O log completo sobe** (`runner:log`).
   - Um handler do `:logger` no runner captura tudo o que passa pelo Logger. O `Output`,
     que escreve no terminal sem passar pelo Logger, também entrega ao coletor.
   - Antes de a conexão existir, o coletor guarda as últimas 2 000 linhas.
   - **Redação antes de sair da máquina:** os valores dos segredos dos jobs em execução,
     das credenciais git, do token do runner e da `ANTHROPIC_API_KEY` viram
     `[redigido]`.
   - Cada linha é cortada em 4 KB. Um lote sai a cada 5 s ou a cada 200 linhas.
   - O teto é de 1 000 linhas por minuto. O excedente vira uma linha `log_dropped` com a
     contagem.
   - Os lotes passam pela outbox e são descartáveis, como `job:event`: os logs que mais
     importam são os de perto de uma queda.
   - **Retenção por workspace:** `runner_log_retention_days`, padrão 7, no backoffice.
     - Com 0, a resposta do join diz `"logs": false` e o runner só envia as linhas que são
       eventos.
     - Isso atende ao §7 do plano, que pede a opção de guardar só metadados.
5. **Eventos operacionais** (`runner_events`, 30 dias).
   - Uma linha de log pode trazer `event`, de uma lista fechada. O control plane a guarda
     também como evento. Do runner, vêm `update_applied`, `update_failed`,
     `scratch_remove_failed`, `outbox_dropped`, `connection_lost`, `log_dropped` e
     `claude_sessions_not_found` (ADR 0053).
   - O control plane deriva eventos do `job:finished`. Isso vale também para runners
     antigos:
     - `setup_failed`;
     - `delivery_failed`, e `credential_refused` quando o erro do git é de autenticação;
     - `worktree_remove_failed`.
   - O doctor gera `doctor_changed` quando um check muda de status.
6. **O auto-update se registra depois de relançar.**
   - Antes de se reexecutar, o runner grava um marcador no diretório de configuração.
   - O binário novo o lê no início e emite a linha `update_applied` ou `update_failed`.
     Ela sobe depois do join.
7. **Doctor remoto** (`runner:doctor`).
   - Cada check ganha uma `key` estável (`claude`, `git`, `gh`, `root`, `disk`,
     `platform`, …).
   - O runner roda o doctor depois de cada join e a cada hora, fora do processo da
     conexão. Conectado, ele pula a checagem da plataforma.
   - O runner responde ao pedido do control plane com o mesmo `request_id`.
   - O control plane guarda o último resultado em `runners.doctor`.
8. **Runner degradado**, calculado no domínio a partir dos dados acima. Os motivos são:
   - disco livre abaixo de 10 % ou de 5 GiB (o limiar do doctor);
   - memória acima de 95 % nas últimas cinco amostras;
   - três quedas ou mais na última hora;
   - mais de 30 % de falhas em 24 h, com pelo menos cinco jobs;
   - algum check do doctor em `error`.

   O estado aparece como selo na lista e na página do runner. No Board, é o primeiro
   alerta com escopo de runner, mostrado para os runners online do workspace.

## Consequências

- Os testes de conexão do runner passam a afirmar também os envios feitos no join
  (saúde, doctor), como já afirmam o uso dos worktrees.
- Com o log completo, um caminho ou um trecho de código que o runner registre chega ao
  control plane. A redação cobre os segredos conhecidos, não conteúdo arbitrário. Quem
  não quer isso põe a retenção em 0.
- A exportação para Prometheus ou Grafana fica para depois. Tudo fica no banco do
  control plane.
- O número de amostras é de cerca de 10 mil por runner por semana. As linhas de log
  dependem do volume do runner e são limitadas pelo teto por minuto.
