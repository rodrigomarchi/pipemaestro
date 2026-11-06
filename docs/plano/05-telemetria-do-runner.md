# Plano — Telemetria do runner

> Versão 0.1 — 06/11/2026
> Decisões: [ADR 0039](../adr/0039-telemetria-do-runner.md). Mensagens:
> [`specs/protocolo-runner.md`](../specs/protocolo-runner.md) §4.7.

## Objetivo

O plano original (§6.2 da [visão](01-visao-arquitetura.md)) pede métricas, logs e
rastreamento dos executores, enviados por eles. Também pede (§8) que um runner mal
configurado mostre a causa da falha no board. A telemetria do **agente** já está completa
(ADRs [0015](../adr/0015-auditoria-da-execucao.md) e
[0024](../adr/0024-resumo-da-execucao-e-metricas-do-agente.md)). Falta a do **runner como
máquina e processo**:

| Hoje | Com este plano |
|---|---|
| Só a última foto do runner (Hello, uso dos worktrees, último connect e último "visto") | Saúde do host em série: CPU, memória, load, disco, outbox e jobs em execução |
| O motivo de uma queda é descartado; um join recusado não deixa rastro | Cada sessão com início, fim e motivo; uptime |
| O `runner.log` só existe na máquina | O log completo no control plane, com redação dos segredos e retenção por workspace |
| Falhas fora do agente (push recusado, remoção de scratch, auto-update) ficam espalhadas ou se perdem | Eventos operacionais por runner, filtráveis |
| O `doctor` só roda na máquina | Doctor no join, a cada hora e sob demanda pela página |
| Nenhum sinal de runner com problema | "Runner degradado" na lista, na página e no Board |

Tudo fica no control plane. Exportar para Prometheus/Grafana fica para depois.

## Telas

- **Lista de executores:** ganha as colunas Saúde (selo com o motivo), Uptime 7d e
  Falhas 7d.
- **Página do runner:** passa a ter abas (`?aba=`):
  - **Visão geral:** o conteúdo de hoje, mais o selo de saúde;
  - **Saúde:** gráficos de 24 h/7 d de CPU, memória, load e disco, e a execução dos
    últimos 7 dias (jobs, falhas, setup p50/p95, fila e gates);
  - **Conexões:** faixa online/offline e as sessões com o motivo de cada queda;
  - **Eventos e logs:** eventos operacionais com filtros e as linhas do log ao vivo;
  - **Diagnóstico:** o último doctor e o botão "Rodar agora".
- **Board:** alerta "runner degradado" para os runners online do workspace.
- **Backoffice (workspace):** dias de retenção do log do runner; 0 = não guardar.

## Fases

A entrega é uma branch só, `feat/telemetria-runner`, com um commit por fase e um único PR
no fim. Cada fase começa pelos testes e fecha com o `make ci` verde. As fases que têm
tela também fecham com `make e2e` e `make e2e.shots`.

| Fase | Entrega |
|---|---|
| 0 | Documentação: este plano, o ADR 0039 e a spec do protocolo |
| 1 | Conexões (só control plane): sessões, motivo da queda, joins recusados, uptime, abas da página do runner, aba Conexões e coluna Uptime 7d |
| 2 | Saúde: `runner:health`, a coleta no runner (macOS e Linux), as amostras, a aba Saúde e a coluna Falhas 7d |
| 3 | Eventos e logs: `runner:log`, o coletor de log com redação, o marcador do auto-update, os eventos derivados do `job:finished`, a retenção por workspace e a aba Eventos e logs |
| 4 | Diagnóstico: `runner:doctor` nos dois sentidos, o doctor periódico e sob demanda e a aba Diagnóstico |
| 5 | Runner degradado: o cálculo, o selo e o alerta no Board |
| 6 | Guias, as capturas das telas e a validação na instância real |

## Como se testa

- **Runner:** testes da `Connection` com `Slipstream.SocketTest`, com intervalos curtos
  por opção. A coleta de saúde é testada com saídas de comando de macOS e de Linux. Há
  testes da redação do coletor de log e do marcador do auto-update.
- **Domínio e web:** testes de canal para cada mensagem, para o `terminate` com cada
  motivo e para o join recusado. Também a poda do `Maintenance` por workspace (inclusive
  com retenção 0), o cálculo de "degradado" para cada motivo e as abas da LiveView.
- **e2e:** o runner real do `RunnerProcess` com intervalos curtos, percorrendo as abas,
  o log ao vivo, o "Rodar agora", e uma parada e subida do runner na aba Conexões. Mais o
  alerta no Board.
- **Na instância real:** um runner atualizado mostra saúde e log em até um minuto, o
  "Rodar agora" devolve o diagnóstico e parar o serviço gera a queda na aba Conexões.
