# Contexto de Discovery — Plataforma de Pipeline de Agentes de IA

> Versão 0.1 — 03/11/2026
> Companheiro de [`01-visao-arquitetura.md`](01-visao-arquitetura.md). Este documento reúne o que foi apurado na pesquisa e na discussão de produto, para que os agentes/pessoas que implementarem o sistema partam do mesmo contexto. Contém fatos verificados em documentação oficial (com data), decisões de tecnologia e suas justificativas, cenário competitivo, benchmarks e problemas conhecidos. Verifique novamente qualquer fato marcado com ⚠ antes de depender dele: o ecossistema muda em semanas.

---

## 1. Motor de agente: Claude Code em modo headless

Fonte: mapa de documentação do Claude Code (atualizado 2026-10-27), https://code.claude.com/docs/en/claude_code_docs_map.md

### 1.1 Por que CLI headless e não SDK
- O Agent SDK existe oficialmente em **TypeScript** (`@anthropic-ai/claude-agent-sdk`) e **Python** (`claude-agent-sdk`, Python 3.10+). Para outras linguagens a própria documentação recomenda rodar a CLI com `-p` e `--output-format json`.
- O executor será em Elixir, então a CLI é a interface. O que se perde: tipagem e controle fino de permissão por chamada. O que se ganha: zero dependência de runtime Node/Python no executor e isolamento natural por processo/container.
- Documentação: https://code.claude.com/docs/en/headless e https://code.claude.com/docs/en/agent-sdk/overview

### 1.2 Recursos da CLI relevantes para o runtime de etapa ⚠ (confirmar flags na versão adotada)
- `-p "<prompt>"`: modo não interativo; existe também um "bare mode" para iniciar mais rápido.
- `--output-format json` (resultado final) ou `stream-json` (eventos linha a linha, inclusive mensagens de subagentes). O stream é o que alimenta o board em tempo real.
- `--json-schema`: força a saída final a obedecer um schema. É a base dos gates de saída estruturada.
- Controle de permissões para execução não assistida: modos de permissão, lista de ferramentas permitidas, e desligamento de prompts de permissão. Em container efêmero o modo mais permissivo aceitável é o que permite edições e comandos dentro do workspace, com negações explícitas em `settings.json`.
- Customização de system prompt por invocação (append/replace), útil se os prompts de etapa não viverem no repositório.
- Continuação/resumo de sessão existe, mas **não deve ser usada entre etapas** (princípio de contexto zerado).
- Encerramento por `SIGTERM` é suportado; tarefas em background são finalizadas ao sair.
- Falha de CI quando plugin/MCP não carrega: existe sinalização para isso no stream; o executor deve tratar como erro de ambiente, não de agente.

### 1.3 Configuração baseada em arquivos (vive no repositório do cliente)
- `CLAUDE.md` e `.claude/rules/`: instruções de projeto; a doc recomenda manter curto e usar regras por caminho. `AGENTS.md` também é lido (compatibilidade com outras ferramentas).
- `.claude/agents/*.md`: subagentes com frontmatter (modelo, esforço, ferramentas permitidas, MCP servers, hooks, memória persistente). É o lugar natural para a definição de cada etapa do pipeline.
- `.claude/skills/`: procedimentos reutilizáveis; podem rodar em subagente.
- `.claude/settings.json`: `permissions.allow`/`deny` (ex.: negar `git push`, negar escrita fora de `src/`), hooks, sandbox.
- **Hooks** (`PreToolUse`, `Stop`, etc.): shell, prompt-based, agent-based e HTTP. A doc explicitamente recomenda `Stop hook` para "enforce the check" (ex.: não terminar sem rodar testes). Hooks são a camada de regras não negociáveis.
- Observação de arquitetura: como o pipeline é definido pelo projeto, o executor deve **ler a definição do pipeline do repositório** e mapear cada etapa para um subagente/skill já presente no repositório. O produto fornece templates que instalam esses arquivos.

### 1.4 Recursos que existem mas não usaremos no caminho principal
- **Agent teams**, **workflows (`ultracode`)**, **cross-session messaging**, **agent view**: orquestração dentro de uma sessão interativa. Nosso orquestrador é externo e determinístico; esses recursos podem ser usados *dentro* de uma etapa (ex.: etapa de auditoria faz fan-out em subagentes), nunca para decidir a ordem das etapas.
- **Worktrees nativos do Claude Code**: ele sabe criar/limpar worktrees e isolar subagentes neles. Nosso gerenciador de workspaces faz isso fora da CLI, mas a convenção `.claude/worktrees/` é bom conhecer para evitar conflito.
- **Routines / scheduled tasks** (nuvem Anthropic, com gatilhos por API e GitHub) e **Claude Projects** (threads que abrem PRs): são produtos adjacentes que resolvem parte do problema sem executor BYO. Ver seção 5.

### 1.5 Prompt caching
- A doc do Claude Code documenta o que invalida o cache (trocar modelo, mudar effort, conectar/remover MCP, mudar plugins, negar ferramenta inteira, compactar) e o que preserva (editar arquivos do repo, editar `CLAUDE.md` mid-session, invocar skills). Para custo, manter modelo/effort/MCP estáveis dentro de uma etapa.

---

## 2. Managed Agents (Anthropic) — por que não é o executor, e o que aproveitar

Fonte: https://platform.claude.com/docs/en/managed-agents/overview (beta `managed-agents-2026-04-01`)

### 2.1 O que é
- Sessões de agente hospedadas pela Anthropic, com sandbox Linux, acesso a GitHub, vaults de credenciais, webhooks, orçamento por sessão, deployments agendados, memory stores, event stream.
- **Session threads**: threads filhas compartilham o sandbox (mesmos arquivos), cada uma com histórico próprio. Isso permitiria "uma sessão por tarefa, uma thread por etapa".
- **Dynamic workflows / workflow runs**: o agente *escreve um programa* que roda outros agentes em fases, com fan-out (até 64 threads simultâneas, 1.000 por run), passagem de resultados entre fases, retry automático de thread falha. Não há passo de aprovação antes do run começar; o código do workflow não é visível (só pedindo ao agente para imprimir).

### 2.2 Limitações que afastaram a opção para o executor
- **Cada sessão é um container novo**; sessões não compartilham filesystem mesmo no mesmo environment. Logo, clone e build por tarefa, nunca por executor quente.
- `packages` do environment são cacheados entre sessões (toolchain), mas o repositório não.
- Existe modalidade **self-hosted sandboxes/workers** (sandbox na infra do cliente), que seria o caminho se um dia quisermos a Anthropic gerindo sessões sem perder o executor BYO.
- Não elegível para ZDR/HIPAA (transcripts persistem até deleção).

### 2.3 O que vale copiar do desenho deles
- Modelo de eventos (`*.created`, `*.status_running/idle/ended`, `phase_started/ended`, `error` com tipo + mensagem segura para log) e a regra "trabalho está pronto quando todos os runs terminaram **e** a sessão foi para idle com `end_turn`".
- Tools devem ser **seguras para chamar duas vezes** (eles rodam agente falho de novo em nova thread). Nosso at-least-once exige o mesmo.
- Orçamento por sessão que **pausa** em vez de matar; lifetime independente da pausa.
- Networking `limited` com `allowed_hosts` e lista de hosts de package managers — base para a política de rede do nosso container.

---

## 3. Stack do produto (Elixir) — escolhas e justificativas

| Necessidade | Escolha | Por quê | Alternativa considerada |
|---|---|---|---|
| Control plane web + tempo real | Phoenix + LiveView | Board em tempo real sem camada JS; PubSub nativo | — |
| Executores conectados | Phoenix Channels + Presence | Conexão de saída do executor, presença e broadcast prontos | Erlang distribution (descartada: NAT, cookie compartilhado, acoplamento) |
| Cliente de Channels no executor | Slipstream (ou `phoenix_client`) | Reconexão, heartbeat, API idiomática | HTTP long-poll |
| Jobs do lado do servidor | Oban (livre) | Retentativas, uniqueness, cron, `Oban.Web`. Papel: webhooks, sync com GitHub, expiração de leases, limpeza | Oban Pro Workflows (pago; desnecessário porque a fila de etapas é tabela própria + dispatcher) |
| Fila de etapas | Tabela própria `stage_jobs` + GenServer Dispatcher | Atribuição depende de executores externos e afinidade; mais transparente que forçar Oban a esperar | Oban como fila de etapas |
| Subprocessos no executor | MuonTrap (ou Exile) | `Port` puro não mata o filho quando o job morre; precisamos derrubar `claude` e netos em timeout | `System.cmd`/`Port` direto |
| Containers no executor | Docker CLI/API a partir do executor | Container efêmero por tarefa, volumes para workspace e caches | Podman (compatível), Firecracker (futuro, executores hospedados) |
| Distribuição do executor | Release Elixir; opcionalmente Burrito (binário único) | Instalação em um comando no cliente | — |
| HTTP para GitHub | Req | Simples, com retry | Tesla |
| Banco | Postgres | Oban exige; multi-tenant por coluna `org_id` + RLS ou schemas | — |

### 3.1 Workspace e performance (decisão central)
- Clone **bare** por repositório no executor, atualizado por `git fetch` incremental.
- `git worktree add` por tarefa a partir do bare (quase instantâneo; compartilha objetos).
- Caches montados por toolchain: pnpm store, `~/.cache/pip`/uv, `~/.m2`, `~/.cargo`, cache de build (Turborepo/Nx/Bazel/Gradle, `tsc --incremental`).
- Testes direcionados quando possível (`--changed`, `--onlyChanged`, testmon).
- Serviços de teste (Postgres, Redis) de pé no host do executor; um banco/schema por tarefa.
- Afinidade: etapas da mesma tarefa no mesmo executor; fallback paga clone.
- Métrica a instrumentar desde a Fase 0: tempo de "ambiente pronto" por etapa. Meta: só a primeira etapa de uma tarefa paga clone/instalação.

---

## 4. Problemas conhecidos deste tipo de sistema (e como o desenho responde)

| Problema | Evidência / origem | Resposta no desenho |
|---|---|---|
| Agente orquestrador imprevisível e caro | Experiência geral; Managed Agents começa runs sem aprovação | Orquestração em código; LLM só dentro da etapa |
| Contaminação de contexto entre etapas (auditor que viu a implementação aprova tudo) | Prática de revisão independente | Contexto zerado por etapa; auditoria em run separado |
| Loops de retentativa infinitos | Relatos sobre ferramentas autônomas "ficam presas em loops" | Limite de retentativas por etapa → decisão humana |
| Processo filho órfão após timeout | `Port` do BEAM não propaga kill | MuonTrap + container efêmero (matar o container mata tudo) |
| Prompt injection via conteúdo do repo/issue | Documentação Anthropic alerta: host permitido = upload permitido | Rede restrita, segredos efêmeros de escopo mínimo, deny de `git push` no agente, push feito pelo executor |
| Force-push quebra revisão e ferramentas de review | Estudo sobre revisão multi-agente cita o problema de "version alignment" | Commits aditivos por etapa; nunca reescrever histórico do branch da tarefa |
| PR gigante e difícil de revisar | Estudos: diferença de qualidade concentrada nos PRs maiores | Limite de tamanho de diff como política de plataforma; artefatos `.md` separados do código |
| Tarefas mal especificadas rendem pior | Estudos: ferramentas autônomas "struggle with ambiguous specs"; aceitação varia muito por tipo de tarefa | Etapa de triagem com saída estruturada "está bem definida?"; pausa humana quando não está |
| Custo de tokens descontrolado | Relatos de billing imprevisível em runs longos (créditos/ACUs) | Limites por etapa/tarefa/org, modelo mais barato em etapas simples, cache estável |
| Executor some no meio | Qualquer sistema de runners | Lease + heartbeat + reatribuição; idempotência de etapas e integrações |
| Dependência de formato de saída da CLI | Flags e formatos mudam entre versões | Runtime de etapa como camada de adaptação; versão mínima suportada declarada; teste de contrato por versão |

---

## 5. Cenário competitivo

Fontes: comparativos de 2026 (firecrawl.dev, daily.dev, rework.com) e estudos acadêmicos sobre o dataset AIDev (MSR 2026 / arXiv). ⚠ Produtos mudam rápido; validar antes de usar em material externo.

### 5.1 Quem faz "issue → PR" hoje
- **GitHub Copilot coding agent**: atribui-se uma issue ao Copilot; roda em ambiente efêmero do GitHub Actions, escreve código, roda testes e abre PR em rascunho. Multi-modelo. Fraqueza citada: tarefas multi-arquivo difíceis; cobrança por créditos imprevisível em runs longos.
- **OpenAI Codex (cloud)**: cada tarefa em sandbox próprio na nuvem; propõe PRs; CLI local suporta paralelismo via worktrees.
- **Devin (Cognition)**: o mais autônomo; VMs em paralelo, uma por tarefa. Críticas: trava em loops, fraco em specs ambíguas; cobrança por ACU. Estudos apontam taxa de revert acima da humana.
- **Cursor Cloud Agents**: VMs isoladas que devolvem PRs; Cursor afirma que 35% dos PRs internos mergeados vêm deles.
- **Anthropic (adjacentes)**: Claude Code na nuvem (sessões web, auto-fix de PRs), Claude Projects (threads → PRs), Routines com gatilhos por API/GitHub, GitHub Action oficial, Code Review. Tudo isso é "um agente, uma sessão, um PR" — não um pipeline multi-etapa com gates e executores BYO.
- **Sweep**: sem release desde fevereiro/2026 (sinal de que "bot que resolve issue" sozinho não se sustentou como produto).

### 5.2 Onde o nosso produto se diferencia
1. **Pipeline multi-etapa definido pelo cliente, com gates mecânicos e pausas humanas**, em vez de uma sessão monolítica.
2. **Executores BYO com workspace quente** — código nunca sai da infra do cliente e o custo de ambiente é pago uma vez por tarefa.
3. **PR como canvas desde o início**, com artefatos de cada etapa versionados — auditabilidade que os concorrentes não oferecem.
4. **Cliente usa a própria API key**: sem marcação sobre tokens, sem lock-in de modelo (hoje Claude Code; a camada de runtime permite outros motores no futuro).
5. **Stacks variadas por labels/imagens**, enquanto os hospedados impõem seu sandbox.

### 5.3 Riscos competitivos
- GitHub e Anthropic podem adicionar etapas/gates nos produtos nativos. Nossa defesa é o executor BYO + pipeline do cliente + independência de vendor de LLM.
- Cliente que já está 100% no GitHub pode preferir o Copilot pela conveniência; o argumento tem que ser previsibilidade, auditoria e custo de ambiente.

---

## 6. Benchmarks e dados empíricos úteis

⚠ Números abaixo vêm de estudos observacionais sobre PRs públicos (dataset AIDev, MSR 2026); não são benchmarks controlados. Servem para calibrar expectativas e métricas do produto, não para comparar modelos.

- **Tipo de tarefa pesa mais que o agente**: documentação ~82% de aceitação vs. ~66% para features (gap de 16 pp maior que a variância entre agentes). Implicação: a triagem deve classificar tipo de tarefa, e as métricas do produto devem ser estratificadas por tipo.
- **Mix de tarefas difere por agente**: Copilot recebe mais fixes (~42%), Claude Code mais features (~52%). Comparações globais confundem capacidade com distribuição.
- **Qualidade pós-merge varia por vendor**: PRs do Codex revertidos em ~metade da taxa humana (6,1% vs 11,5%); Devin ~1,3× a taxa humana; os demais indistinguíveis de humanos. Agentes em geral têm **menos** "security smells" que humanos (OR 0,63), com a diferença concentrada em PRs grandes.
- **Devin em SWE-bench (histórico)**: 13,86% em março/2024 vs. 1,96% anterior — útil só como marco; os números atuais de SWE-bench Verified são muito mais altos e mudam a cada release de modelo. ⚠ Buscar o valor corrente antes de citar.
- **Revisão multi-agente**: relatos de 30–60% de redução no ciclo de revisão e 25–35% menos defeitos em produção; arquiteturas coder–tester–reviewer reduzem drasticamente injeção de código. Sustenta a etapa de auditoria independente.

### 6.1 Métricas que o produto deve coletar desde a Fase 0
- Taxa de PRs mergeados sem alteração / com alteração / fechados, por tipo de tarefa.
- Taxa de revert pós-merge (via webhook de reverts/follow-up PRs).
- Tempo e tokens por etapa; tempo de "ambiente pronto"; retentativas por etapa; decisões humanas por tarefa e tempo até resolução.
- Tamanho do diff por PR.

---

## 7. Fatos de produto Anthropic que afetam termos/segurança

- Automação headless deve usar **API key** (ou provedores Bedrock/Vertex/Foundry). Terceiros não podem oferecer login/limites do claude.ai nos seus produtos sem aprovação prévia.
- Branding para parceiros: "Claude Agent" ou "Powered by Claude" são permitidos; "Claude Code" como nome de feature do nosso produto não é.
- Documentação de referência: https://docs.claude.com (API), https://code.claude.com/docs (Claude Code), https://support.claude.com (claude.ai).

---

## 8. Lacunas de pesquisa (fazer antes/durante a Fase 0)

1. Confirmar na versão adotada da CLI: flags exatas de permissão não interativa, `--json-schema`, formato de `stream-json`, código de saída em falha de hook/gate.
2. Medir empiricamente: tempo de boot de container com caches montados; overhead de `claude` iniciando em bare mode; custo típico por etapa com modelos diferentes.
3. GitHub App: permissões mínimas para abrir PR em rascunho, commitar artefatos, comentar em issues, emitir tokens de instalação por repositório (credencial efêmera por tarefa).
4. Estratégia de imagens de toolchain: catálogo base do produto vs. Dockerfile no repo do cliente (questão em aberto 4 do plano).
5. Política de rede do container: lista mínima de hosts (API Anthropic, host git, registries) e como o cliente adiciona exceções.
6. Pesquisar o estado atual de SWE-bench Verified e de estudos sobre PRs de agentes para material de marketing (os números deste documento envelhecem rápido).

---

## Fontes consultadas

- Mapa de docs do Claude Code: https://code.claude.com/docs/en/claude_code_docs_map.md
- Agent SDK: https://code.claude.com/docs/en/agent-sdk/overview
- Managed Agents — workflow runs: https://platform.claude.com/docs/en/managed-agents/workflow-runs
- Managed Agents — environments: https://platform.claude.com/docs/en/managed-agents/environments
- Índice da plataforma Anthropic: https://platform.claude.com/llms.txt
- Comparing AI Coding Agents: A Task-Stratified Analysis of PR Acceptance (MSR 2026): https://arxiv.org/html/2602.08915v2
- Not All Agents Are Equal: Code Quality and Post-Merge Maintenance (arXiv, 2026): https://arxiv.org/html/2609.17598v1
- How AI Coding Agents Modify Code (MSR 2026): https://arxiv.org/html/2601.17581v3
- Best AI Coding Agents in 2026 (Firecrawl): https://www.firecrawl.dev/blog/best-ai-coding-agents
- The best AI coding agents in 2026, compared (daily.dev): https://daily.dev/blog/best-ai-coding-agents-comparison/
- Best AI Coding Agents in 2026 (rework): https://resources.rework.com/tools/ai-agents/best-ai-coding-agents-2026
- Autonomous Code Review: Multi-Agent Approaches (zylos.ai): https://zylos.ai/research/2026-04-22-autonomous-code-review-multi-agent-pr-analysis/
