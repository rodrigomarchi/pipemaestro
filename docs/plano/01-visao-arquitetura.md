# Plano de Produto — Plataforma de Pipeline de Agentes de IA para Engenharia

> Versão 0.1 — 03/11/2026
> Status: rascunho para validação. Este documento descreve visão, macro features, arquitetura, requisitos e restrições. Não trata de implementação nem de código.

---

## 1. Visão

Uma plataforma SaaS que recebe tarefas de engenharia (bugs, features, refactors) e as conduz, de forma previsível e auditável, por um pipeline de agentes de IA até um Pull Request pronto para revisão humana. O objetivo é escalar o trabalho de engenharia assistido por IA sem depender de um desenvolvedor operando um console por tarefa.

O produto não substitui a revisão humana: ele a concentra nos pontos onde ela importa (decisões, aprovações, merge e deploy) e automatiza o resto.

### Princípios de projeto

1. **Orquestração determinística, trabalho não determinístico.** A ordem e as transições do pipeline são decididas por código do produto; apenas o conteúdo de cada etapa é produzido por agentes.
2. **Contexto zerado por etapa, comunicação por artefatos.** Cada etapa roda com contexto novo e lê/escreve artefatos versionados no repositório. Nunca se passa transcript entre etapas.
3. **Gates objetivos.** A passagem entre etapas depende de verificações mecânicas (testes, schema, lint), não da opinião do agente.
4. **Falhar para o humano.** Quando algo foge do esperado, o pipeline pausa e cria uma decisão para uma pessoa, em vez de insistir.
5. **Código fica onde o cliente quer.** Executores BYO rodam na infra do cliente; o control plane nunca precisa do código-fonte.
6. **Ambiente quente, sessão descartável.** O custo caro (clone, dependências, build) é pago uma vez por tarefa; as sessões de agente são baratas e descartáveis.

---

## 2. Decisões já tomadas

| Tema | Decisão | Consequência arquitetural |
|---|---|---|
| Escopo | SaaS multi-tenant desde o início | Isolamento por organização em dados, segredos, executores, custos e auditoria |
| Repositórios | Muitos repos, stacks variadas | Roteamento de jobs por labels; imagens de toolchain por repositório |
| Aprovação humana | PR aberto no início; artefatos commitados como `.md`; pipeline pausa e cria tarefa humana quando precisa de decisão | PR é o "canvas" da tarefa; modelo de decisões humanas como entidade de primeira classe |
| Isolamento | Container efêmero por tarefa no executor | Executor orquestra containers; caches compartilhados via volumes |
| Executores | BYO primeiro; hospedado depois, mesmo protocolo | Protocolo executor↔servidor é contrato público e estável |
| Integrações MVP | GitHub (código) + GitHub Issues (tarefas) | Camada de adaptadores existe, mas só GitHub é implementado no MVP |
| Definição do pipeline | ~~Totalmente definido pelo projeto, versionado no repo do cliente~~ → **persistido no control plane, por workspace, genérico e reutilizável entre projetos** ([ADR 0005](../adr/0005-pipelines-e-tarefas.md)) | Produto fornece motor + templates de partida; pipeline é dado, não código do produto; o específico de cada projeto vem do próprio repo (`CLAUDE.md`, `AGENTS.md`) |
| Custo de LLM | Cliente usa a própria API key | Chave do cliente nunca transita pelo control plane; medição de uso é informativa, não base de cobrança |
| Motor de agente | Claude Code via CLI (modo headless) dentro do container do executor | Agentes, skills, hooks e permissões definidos em arquivos no repositório do cliente |

---

## 3. Personas

- **Tech lead / Eng manager**: cria e prioriza tarefas, acompanha o board, toma decisões quando o pipeline pausa, revisa PRs.
- **Engenheiro**: define o pipeline do projeto (etapas, prompts, gates), ajusta o ambiente do executor, revisa e faz merge.
- **Admin da organização**: conecta GitHub, cadastra executores, gerencia membros, segredos e limites.
- **Operador de infra do cliente**: instala e mantém executores BYO.

---

## 4. Macro features

### 4.1 Ingestão de tarefas
- Receber tarefas via GitHub Issues (webhook) com um gatilho explícito (label, comando em comentário ou atribuição).
- Normalizar a tarefa num modelo interno independente da fonte (título, descrição, repositório, prioridade, autor, links).
- Camada de adaptadores de fonte de tarefas preparada para ClickUp, Jira e Linear em versões futuras.

### 4.2 Pipeline definido pelo projeto
- O projeto versiona a definição do pipeline no próprio repositório (um arquivo de configuração declarativo).
- A definição descreve: etapas ordenadas, qual agente/prompt cada etapa usa, quais artefatos lê e escreve, quais gates precisam passar, onde há pausas humanas obrigatórias, modelo e limites (turnos, tempo, custo) por etapa.
- O produto fornece templates de partida (ex.: *bug fix*, *feature*, *refactor*, *dependency upgrade*) com as etapas de referência: triagem → investigação → reprodução com testes → implementação → validação e auditoria → PR pronto.
- Validação da definição no momento da ingestão: pipeline inválido gera erro visível antes de gastar recursos.

### 4.3 Execução com executores distribuídos
- Executores são daemons instalados pelo cliente que fazem conexão de saída ao control plane e puxam trabalho.
- Cada executor se anuncia com labels (repositórios que atende, toolchains, sistema operacional, capacidade).
- O control plane atribui etapas a executores elegíveis, com afinidade por tarefa (as etapas de uma mesma tarefa preferem o mesmo executor, para reaproveitar o workspace).
- Cada etapa roda num container efêmero criado pelo executor, com o workspace da tarefa e caches de dependências/build montados.
- Lease com expiração e heartbeat: executor que some tem seu trabalho reatribuído.

### 4.4 PR como canvas da tarefa
- O PR é aberto (em rascunho) no início do pipeline, num branch dedicado à tarefa.
- Cada etapa commita seus artefatos como arquivos Markdown/JSON numa pasta convencionada do branch (ex.: resultado da triagem, hipótese de causa raiz, plano, relatório de auditoria).
- A descrição do PR é atualizada a cada etapa com um resumo do estado e links para os artefatos.
- O que não cabe no Markdown nem deve ir para o git (screenshots, relatórios, CSVs) o agente copia para a pasta do job, `CP_FILES_DIR`, fora do worktree; o runner sobe esses arquivos e a tarefa os mostra como anexos da etapa ([ADR 0042](../adr/0042-arquivos-gerados-pela-etapa.md)).
- Ao final, o PR sai de rascunho e é marcado como pronto para revisão humana. O produto nunca faz merge nem deploy.

### 4.5 Decisões humanas
- Quando uma etapa precisa de aprovação (por definição do pipeline) ou quando um gate falha repetidamente, o pipeline entra em estado *aguardando decisão*.
- Uma decisão é uma entidade com contexto (etapa, artefatos, pergunta, opções), responsável sugerido e prazo.
- A decisão é exposta na UI do produto e refletida na fonte da tarefa (comentário/label na issue) e no PR.
- A pessoa decide (aprovar, ajustar com instruções, abortar); o pipeline retoma a partir dali com a decisão registrada como artefato.

### 4.6 Gates e qualidade
- Gates mecânicos entre etapas: saída estruturada validada por schema; suíte de testes; lint; regras específicas (ex.: teste de reprodução deve falhar antes do fix e passar depois).
- Etapa de auditoria roda num contexto que não viu a implementação.
- Política de retentativas por etapa com limite; esgotado o limite, vira decisão humana.
- Regras não negociáveis aplicadas por configuração no repositório (o agente não pode fazer push, não pode editar fora de diretórios permitidos, não pode encerrar sem rodar testes).

### 4.7 Observabilidade e board
- Board em tempo real por organização: tarefas por etapa, executores online e sua carga, decisões pendentes.
- Linha do tempo por tarefa: eventos de cada etapa, duração, turnos, tokens, resultado dos gates, retentativas.
- Log de eventos do agente por etapa (stream), com retenção configurável.
- Alertas: tarefa travada, executor offline, gate falhando repetidamente, custo acima do esperado.

### 4.8 Organização, acesso e segredos
- Organizações (tenants), projetos (repositórios), membros e papéis.
- Conexão com GitHub via GitHub App instalada pela organização.
- Credenciais git de curta duração emitidas por tarefa e entregues ao executor junto com o job.
- API key da Anthropic configurada e armazenada no executor do cliente; o control plane nunca a recebe.
- Tokens de executor revogáveis; auditoria de quem fez o quê.

### 4.9 Uso e limites
- Medição por tenant/projeto/tarefa/etapa: tokens, turnos, tempo de executor, tarefas processadas.
- Limites configuráveis por organização e por pipeline (máximo de tarefas concorrentes, orçamento de tokens por tarefa, tempo máximo por etapa).
- Relatórios de uso para o cliente planejar seu consumo de API.

---

## 5. Arquitetura

### 5.1 Visão geral

```
 GitHub (Issues, Repos, PRs)
        │ webhooks / API
        ▼
┌─────────────────────────────────────────────┐
│               CONTROL PLANE (SaaS)          │
│  Ingestão │ Motor de pipeline │ Dispatcher  │
│  Decisões │ Board em tempo real │ Auditoria │
│  Tenants/Acesso │ Segredos │ Uso e limites  │
└───────────────▲─────────────────────────────┘
                │ conexão persistente de saída (executor → servidor)
   ┌────────────┴───────────┐    ┌────────────────────┐
   │ EXECUTOR BYO (cliente) │    │ EXECUTOR BYO (dev) │  ... N executores
   │  Workspaces quentes    │    │  máquina local     │
   │  ┌──────────────────┐  │    └────────────────────┘
   │  │ Container efêmero│  │
   │  │  claude (headless)│ │──► API Anthropic (chave do cliente)
   │  └──────────────────┘  │
   └────────────────────────┘
```

### 5.2 Componentes do control plane

| Componente | Responsabilidade |
|---|---|
| **Gateway de integrações** | Recebe webhooks (GitHub), valida assinaturas, normaliza eventos. Adaptadores por fonte de tarefa e por host de git. |
| **Registro de tarefas e pipelines** | Modelo de dados de organização, projeto, tarefa, execução de pipeline, etapa, artefato, decisão, executor, lease. |
| **Motor de pipeline** | Interpreta a definição do projeto, mantém a máquina de estados de cada execução, decide a próxima etapa, aplica gates do lado do servidor, gerencia retentativas e pausas. |
| **Dispatcher** | Casa etapas enfileiradas com executores elegíveis (labels, capacidade, afinidade). Emite leases, acompanha heartbeats, reatribui. |
| **Serviço de executores** | Canal persistente com cada executor; presença, autenticação, protocolo de mensagens, stream de eventos. |
| **Serviço de decisões** | Cria, notifica e resolve decisões humanas; reflete nas integrações. |
| **Serviço de PR** | Abre o PR em rascunho, atualiza descrição e estado, marca como pronto. |
| **Serviço de segredos** | Emite credenciais git de curta duração por tarefa; guarda tokens de executor e configurações da GitHub App. |
| **Medição e limites** | Agrega métricas de uso; aplica os tetos que o tenant configurou. |
| **Jobs internos** | Trabalhos do próprio servidor: sincronizações, expiração de leases, limpeza, notificações, relatórios. |
| **Interface web** | Board em tempo real, detalhe da tarefa, decisões pendentes, executores, configuração da organização. |

### 5.3 Componentes do executor

| Componente | Responsabilidade |
|---|---|
| **Agente de conexão** | Conecta ao control plane, autentica, anuncia labels/capacidade, mantém heartbeat, recebe jobs. |
| **Gerenciador de workspaces** | Mantém um clone base por repositório com atualização incremental; cria um workspace por tarefa derivado dele; remove ao fim. |
| **Gerenciador de caches** | Volumes compartilhados de dependências e build por toolchain; política de limpeza. |
| **Runtime de etapa** | Sobe um container efêmero a partir da imagem de toolchain do repositório, monta workspace e caches, injeta segredos efêmeros, executa o agente em modo headless com os parâmetros da etapa, faz stream dos eventos, aplica timeout e encerra o container. |
| **Executor de gates locais** | Roda testes, lint e verificações definidas no pipeline dentro do mesmo container, antes de reportar a etapa como concluída. |
| **Relator** | Envia eventos, heartbeats, artefatos e resultado estruturado ao servidor. |

### 5.4 Protocolo executor ↔ control plane (contrato)

- Conexão sempre iniciada pelo executor; nenhuma porta de entrada no cliente.
- Mensagens essenciais: anúncio (labels, versão, capacidade), atribuição de job (lease, tarefa, etapa, parâmetros, segredos efêmeros), eventos de progresso, heartbeat, conclusão (resultado estruturado + referências de artefatos), cancelamento.
- Versionado; executores antigos continuam funcionando por uma janela de compatibilidade definida.
- O mesmo contrato será usado pelos executores hospedados no futuro.

### 5.5 Fluxo de uma tarefa (referência)

1. Issue recebe o gatilho → gateway normaliza → execução de pipeline criada com a definição lida do repositório.
2. Dispatcher escolhe executor; executor prepara workspace (clone base atualizado + workspace da tarefa).
3. PR em rascunho é aberto no branch da tarefa.
4. Para cada etapa: container efêmero → agente lê artefatos anteriores → produz saída estruturada e artefatos → gates locais → resultado ao servidor → gates do servidor → commit dos artefatos → próxima etapa (ou pausa para decisão).
5. Última etapa marca o PR como pronto para revisão. Workspace é liberado. Tarefa fica em *aguardando humano*.
6. Merge e deploy são feitos por pessoas, fora do produto.

### 5.6 Modelo de dados (entidades principais)

Organização · Membro/Papel · Projeto (repositório + configuração) · Executor · Tarefa · Execução de pipeline · Etapa (instância) · Lease · Artefato · Decisão · Evento · Registro de uso.

---

## 6. Requisitos

### 6.1 Funcionais (resumo por feature)

- RF-01 Ingerir issues do GitHub por gatilho explícito e criar execuções de pipeline.
- RF-02 Ler, validar e aplicar a definição de pipeline versionada no repositório do projeto.
- RF-03 Fornecer templates de pipeline instaláveis num repositório.
- RF-04 Registrar executores com labels e capacidade; mostrar presença em tempo real.
- RF-05 Atribuir etapas a executores com afinidade por tarefa e reatribuição em falha.
- RF-06 Abrir e manter o PR como canvas da tarefa, com artefatos commitados por etapa.
- RF-07 Pausar o pipeline e criar decisões humanas conforme definição ou falha de gate.
- RF-08 Resolver decisões pela UI ou pela fonte da tarefa e retomar o pipeline.
- RF-09 Aplicar gates mecânicos e políticas de retentativa por etapa.
- RF-10 Exibir board, linha do tempo e stream de eventos por tarefa.
- RF-11 Emitir credenciais git efêmeras por tarefa; nunca armazenar a API key do cliente no servidor.
- RF-12 Medir uso por tenant/projeto/tarefa/etapa e aplicar limites configuráveis.
- RF-13 Administração de organização, membros, papéis e integrações.

### 6.2 Não funcionais

- **Isolamento multi-tenant**: nenhum dado, evento, segredo ou executor de uma organização é acessível por outra; chaves de criptografia e escopos por tenant.
- **Previsibilidade**: dada a mesma definição de pipeline, a ordem e as condições de transição são determinísticas; toda transição é registrada com causa.
- **Confiabilidade**: entrega *at-least-once* para etapas; todas as etapas e integrações são idempotentes; leases expiram e são reatribuídos sem intervenção.
- **Performance**: nenhuma etapa além da primeira de uma tarefa paga clone ou instalação de dependências no caminho feliz; início de container de etapa na ordem de segundos; atualização do board em tempo real.
- **Segurança**: executor sem portas de entrada; segredos efêmeros por job; permissões do agente restritas por configuração no repositório; rede do container restrita ao necessário (API da Anthropic, registries, host git).
- **Auditabilidade**: trilha completa de quem/o quê/quando por tarefa, incluindo decisões humanas e eventos do agente, com retenção configurável.
- **Observabilidade**: métricas, logs e rastreamento tanto do control plane quanto dos executores (telemetria enviada pelo executor).
- **Compatibilidade**: executores de versões anteriores continuam operando por uma janela definida; definição de pipeline versionada com migração assistida.
- **Operabilidade do executor**: instalação em um comando, atualização automática opcional, diagnóstico local.

---

## 7. Restrições

- O motor de agente é o Claude Code em modo headless; o produto depende das capacidades e do formato de saída dessa CLI e deve isolar essa dependência atrás do runtime de etapa.
- Uso de API key da Anthropic do cliente para execuções automatizadas (não login de conta pessoal). A chave vive no executor do cliente.
- O produto nunca faz merge, deploy ou push em branches protegidos; toda escrita no git é restrita ao branch da tarefa.
- Executores BYO exigem Docker (ou runtime de containers compatível) e acesso de saída à internet para o control plane, host git, registries e API da Anthropic.
- Imagens de toolchain por repositório são responsabilidade do cliente (o produto fornece imagens base e um guia).
- O MVP suporta apenas GitHub como host de git e GitHub Issues como fonte de tarefas.
- Dados de transcript/eventos do agente podem conter trechos de código; a retenção no control plane deve ser configurável pelo cliente, com opção de manter apenas metadados.

---

## 8. Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Agente faz alterações destrutivas ou foge do escopo | Container efêmero, permissões negativas no repositório, gates mecânicos, auditoria por etapa |
| Prompt injection via conteúdo do repositório ou da issue | Rede restrita no container, segredos efêmeros de escopo mínimo, sem push fora do branch da tarefa |
| Executor BYO mal configurado gera falhas opacas | Diagnóstico local no executor, validação da imagem de toolchain antes da primeira tarefa, erros com causa explícita no board |
| Custo de tokens descontrolado | Limites por etapa/tarefa/organização, alertas, medição visível |
| Dependência de mudanças na CLI/formato de saída | Runtime de etapa como camada de adaptação; versão mínima suportada declarada |
| Afinidade por executor reduz paralelismo | Afinidade é preferência, não exigência; fallback para outro executor com custo de clone |
| Pipeline definido pelo cliente é inválido ou perigoso | Validação de schema, limites de plataforma (tempo, turnos, tamanho), políticas que o cliente não pode desligar |

---

## 9. Roadmap proposto

### Fase 0 — Prova de conceito (interno)
- Um repositório, um executor na máquina local, pipeline fixo de 6 etapas, PR como canvas, board mínimo.
- Objetivo: validar a cadeia completa issue → PR e medir tempo/custo por etapa.

### Fase 1 — MVP single-tenant pronto para pilotos
- Pipeline definido pelo repositório com templates.
- Executores BYO instaláveis, labels, afinidade, leases.
- Decisões humanas com reflexo na issue e no PR.
- Gates mecânicos configuráveis, retentativas, limites.
- Board, linha do tempo e stream de eventos.

### Fase 2 — Multi-tenant e segurança
- Organizações, papéis, GitHub App por organização, segredos efêmeros, auditoria, retenção configurável.
- Medição de uso e limites por tenant.
- Hardening do executor (atualização, diagnóstico, compatibilidade de versões).

### Fase 3 — Expansão
- Executores hospedados usando o mesmo protocolo.
- Adaptadores: GitLab; ClickUp, Jira, Linear.
- Templates avançados, métricas de qualidade (taxa de PRs aceitos sem alteração, retrabalho por etapa).
  - As métricas de qualidade estão na aba Qualidade do Uso ([ADR 0054](../adr/0054-qualidade-das-entregas.md)); a taxa de revert pós-merge e o tamanho do diff por PR continuam em aberto.

---

## 10. Questões em aberto

1. Formato e escopo da definição de pipeline no repositório: quanto de prompt vive no arquivo de pipeline versus em arquivos de agente/skill separados.
2. Como o gatilho na issue é expresso (label, comando, atribuição a um usuário-bot) e quem pode acioná-lo.
3. Política padrão de retenção de eventos do agente no control plane (metadados apenas vs. conteúdo completo).
4. Estratégia para imagens de toolchain: catálogo mantido pelo produto, Dockerfile no repositório do cliente, ou ambos.
5. Como representar decisões humanas na issue do GitHub (comentário com opções, labels, formulário no PR) e se há SLA.
6. Limites de plataforma não desligáveis pelo cliente (tempo máximo de etapa, turnos, tamanho de diff) e seus valores iniciais.
7. Modelo de licenciamento/cobrança da plataforma (por executor, por tarefa, por assento) — fora do escopo técnico, mas influencia a medição.

---

## 11. Próximos passos sugeridos

1. Validar este plano e fechar as questões em aberto 1, 2 e 4 (são as que afetam a Fase 0).
2. Escrever o contrato do protocolo executor ↔ control plane (mensagens, estados, versionamento).
3. Definir o schema da definição de pipeline e um template de referência (*bug fix*).
4. Especificar o modelo de dados e a máquina de estados de execução/etapa/decisão.
5. Iniciar a Fase 0 com um repositório interno real e um executor local.
