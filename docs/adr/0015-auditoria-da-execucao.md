# 0015 — Auditoria da execução do claude

- **Status:** aceita
- **Data:** 03/11/2026

## Contexto

O control plane já conduzia o pipeline. Faltava servir também para auditar como o
Claude Code trabalha. Da saída do CLI, o runner guardava pouco: custo, duração, turnos
e eventos resumidos. Ficavam de fora:

- a sessão e os tokens com o cache separado;
- o custo por modelo e as negações de permissão;
- as ferramentas, os MCP servers e os agentes disponíveis;
- o raciocínio, os retries da API e as compactações;
- o stderr de uma execução que deu certo.

Também não havia telemetria do CLI.

Uma execução real (`claude` 2.1.317, haiku), capturada antes de escrever o código, mostrou
o que o CLI emite de fato. Ela virou fixture dos testes do protocolo e do runner. Três
achados que a documentação não trazia:

- **Raciocínio:** em `-p`, o texto vem vazio; só aparecem a duração e a estimativa de
  tokens.
- **Decisões de permissão:** cada `tool_result` traz a decisão que deixou a ferramenta
  rodar (`tool_result_meta`).
- **Limites da conta:** o uso das janelas de 5 horas e de 7 dias chega num
  `rate_limit_event`.

## Decisões

1. **Três fontes.**
   - **O `stream-json`**, passado a extrair tudo o que serve para auditar
     (`ClaudeControlPlaneProtocol.JobEvent`):
     - eventos novos: `thinking`, `api_retry`, `compact`, `permission_denied`,
       `rate_limit`;
     - os tokens de cada mensagem com o cache separado, contados uma vez por mensagem;
     - o `result` com os totais, o custo por modelo, as negações, os erros e os
       subagentes.
   - **A telemetria OpenTelemetry do CLI:** latência e custo de cada chamada à API,
     erros, duração de cada ferramenta, decisões de permissão, conexões MCP e métricas
     de linhas, commits, PRs e tempo ativo.
   - **Medidas do próprio runner:** o tempo do processo do agente e o stderr.
2. **Um receptor OTLP local no runner.**
   - Um servidor Bandit com um plug próprio, em 127.0.0.1 e numa porta que o sistema
     escolhe, recebe o OTLP `http/json` do CLI (`Telemetry.Receiver` e
     `Telemetry.Exports`).
   - Usar Bandit e Plug, já usados no control plane, é o padrão da comunidade para
     HTTP: cuida de keep-alive, de corpo em partes e de pedido malformado. O runner
     continua sem Phoenix e sem Ecto.
   - Cada job leva `OTEL_RESOURCE_ATTRIBUTES=cp.job_id=<id>`, e assim cada registro
     sabe de qual job é.
   - O runner repassa os registros como `job:telemetry`.
   - Eles podem chegar depois do `job:finished`: o CLI exporta ao sair, e o control
     plane os aceita com o job já terminado.
   - Nada sai da máquina além do que já ia ao control plane.
3. **Sem dados da pessoa e sem conteúdo na telemetria.**
   - Só os atributos de uma lista fechada passam (`ClaudeControlPlaneProtocol.Telemetry`).
     E-mail, conta e organização ficam no runner.
   - O conteúdo de prompts, respostas e argumentos fica desligado no CLI, porque os
     eventos já o trazem.
4. **Só estruturado.**
   - O `stream-json` bruto não é guardado.
   - Os limites de texto subiram para 32 KB nos eventos e 16 KB nos argumentos.
   - Ferramentas MCP passam a ter os argumentos em JSON, em vez de um resumo.
5. **Onde fica.**
   - **No job:** colunas para a sessão, os tempos e os tokens, que as consultas somam;
     mapas para o custo por modelo, as negações, os subagentes e o ambiente; o
     `stderr`; e os `telemetry_totals`, as métricas somadas.
   - **Tabela `job_telemetry`:** os registros da telemetria.
   - **Retenção:** a `Maintenance` apaga a telemetria junto com os eventos, 30 dias
     depois do fim do job. O job mantém os totais.
6. **Consolidação.**
   - `ClaudeControlPlane.Insights` junta tudo:
     - **por job:** ferramentas, API, cache, modelos, compactações, subagentes,
       raciocínio e limites;
     - **por workspace e período:** tokens, cache, modelos, ranking de ferramentas, API,
       negações e compactações.
   - O `Usage` passa a somar tokens.
7. **Onde aparece.**
   - **Página do job:** a seção "Auditoria", que se atualiza quando a telemetria
     chega.
   - **Linha do tempo:** "Pensou…", retries, compactações, negações, chamadas de
     subagente indentadas e o filtro "Raciocínio".
   - **Página da tarefa:** tokens por tentativa de etapa.
   - **Uso e limites:** a seção "Agente".

## Consequências

- **Formato do CLI:** o `stream-json` e a telemetria podem mudar entre versões. A captura
  real nas fixtures faz uma mudança de formato aparecer nos testes.
- **Hooks do Claude Code:** ficaram de fora. O que dariam já chega pela telemetria e
  pelos eventos.
- **Tokens por mensagem:** a saída de cada mensagem no `stream-json` é provisória, e o
  número real vem no `result` e nos `api_request` da telemetria. A linha do tempo mostra
  o de cada mensagem e a auditoria usa os totais.
