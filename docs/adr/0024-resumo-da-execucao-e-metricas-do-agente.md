# 0024 — Resumo da execução e métricas do agente

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

A ADR 0015 passou a coletar quase tudo o que o Claude Code expõe: eventos do
stream-json (`job_events`), a OpenTelemetry do CLI (`job_telemetry`) e o resultado
final (colunas de `jobs`). A auditoria do job e a visão do workspace recalculavam tudo
a partir dos eventos e da telemetria a cada leitura. Uma revisão encontrou lacunas:

- **A retenção apagava a auditoria.** O `Maintenance` apaga eventos e telemetria dos
  jobs encerrados há mais de 30 dias. A auditoria de um job antigo passava a dizer
  "nenhuma ferramenta", e o workspace não podia olhar além de 30 dias.
- **Propostas e jobs avulsos não tinham corte próprio** em Uso. Os cortes por pipeline
  e por etapa só viam jobs de etapa.
- **O rate limit de cada conta** só aparecia dentro de um job, e cada runner usa o login
  Claude de alguém.
- **Dados gravados sem tela:** tempo ativo, conexões MCP, decisões de permissão,
  subagentes concluídos, recusas da API e a origem de cada chamada à API.
- **O tempo não era decomposto** em fila, preparação, API, ferramentas e gates.
- **A auditoria só aparecia com o job encerrado.**

## Decisão

- **Um resumo guardado por execução.** `Insights.summarize/1` consolida eventos,
  telemetria e colunas num mapa que fica em `jobs.insights`, e as ferramentas vão para
  `job_tool_stats`, uma linha por ferramenta. O resumo é gravado:
  - quando o job termina;
  - de novo a cada lote de telemetria que chega depois do fim;
  - pelo `Maintenance`, antes de apagar eventos e telemetria (a versão final) e para os
    jobs encerrados que ainda não têm resumo.

  A auditoria do job lê o resumo. A visão do workspace soma resumos e
  `job_tool_stats`, então independe da retenção, e Uso oferece 90 dias.
- **As ferramentas contam pelos eventos e pela telemetria.** Uma chamada vista como
  `tool_use` leva o tempo do `tool_result` da telemetria. Uma vista só pela telemetria
  também conta.
- **Cortes de custo:**
  - por origem: etapas de pipeline, propostas por tipo e execuções avulsas;
  - um filtro de pipeline, que vale para o relatório e para a visão do agente;
  - o custo de cada PR.
- **O limite da conta fica no runner.** Um evento `rate_limit` grava em
  `runners.rate_limit` e avisa as telas de runners. Um runner está perto do limite
  (`Runners.near_limit?/2`) com uma janela em 80% ou mais, ou com um status diferente
  de `allowed`, até a hora de renovação. Isso aparece:
  - como barras por janela no runner;
  - como selo na lista de runners;
  - num card em Uso;
  - como alerta no Board para tarefas em andamento naquele runner.
- **O tempo decomposto** fica no resumo (`timing`): fila, preparação, gates, API,
  ferramentas (somadas, porque podem rodar ao mesmo tempo) e o processo inteiro. Em
  Uso, cada etapa mostra a média de fila e de gates.
- **Os extras do resumo** (`extras`) cobrem tempo ativo, conexões MCP e as falhas
  delas, decisões de permissão por origem, subagentes por tipo e requisições e custo
  por origem da chamada.
- **Durante a execução**, a tela do job e a etapa em andamento da tarefa mostram custo,
  tokens, requisições e ferramentas até o momento (`Insights.live/1`). Os valores vêm
  da telemetria e são relidos no máximo a cada 2 s.

O protocolo não muda. Tudo isso já chegava ao control plane.

## Consequências

- Uma auditoria lida depois da retenção é igual à lida no dia. O que se perde são os
  eventos e registros individuais, não os números.
- Um campo novo na auditoria entra em `summarize/1`. Jobs já resumidos só o ganham se
  o resumo for gravado de novo, enquanto os eventos ainda existirem.
- A visão do workspace depende do resumo. Um job encerrado sem resumo só entra nela
  depois da passada seguinte do `Maintenance`, que roda a cada hora.
