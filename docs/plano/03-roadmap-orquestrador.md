# Roadmap — um orquestrador de Claude poderoso (antes da integração com git)

> Versão 0.3 — 03/11/2026 (marcos 1 a 6 e as pendências implementados; o que resta na seção 5)
> Companheiro de [`01-visao-arquitetura.md`](01-visao-arquitetura.md). Registra o
> estado atual e o caminho até um orquestrador completo **operando como hoje**: o
> runner roda na máquina do dev, a tarefa trabalha num diretório dela, e commit,
> push e PR ficam a critério do prompt. A integração com git e GitHub (issue como
> entrada, PR como canvas) é deliberadamente a **última** etapa.

---

## 1. Onde estamos

O meio da cadeia da Fase 0 já existe:

- **Runner BYO:**
  - login por device flow, conexão de saída e presença ao vivo, revogação;
  - execução do `claude -p` em stream;
  - cancelamento pelo grupo de processos;
  - diretórios oferecidos a partir de uma raiz e worktree por tarefa.

  Referências: ADRs [0003](../adr/0003-conexao-do-runner.md), [0004](../adr/0004-execucao-de-jobs-no-runner.md) e [0005](../adr/0005-pipelines-e-tarefas.md).
- **Pipelines:** persistidos no control plane, editáveis e versionados, com retrato da
  versão por tarefa e templates de partida.
- **Tarefas:** etapas com contexto novo, artefatos em `.control-plane/<tarefa>/`, gate
  por contrato de saída (`ok`/`bloqueado`) com artefato e retentativas, pausa para
  decisão (refazer ou seguir com instruções, ou cancelar). A tela mostra um pipeline
  vertical, com a etapa em execução ao vivo.
- **Medição:** custo, duração e turnos por etapa.

### Divergências do plano original que continuam abertas

| Tema | Plano | Hoje | Onde é tratado |
|---|---|---|---|
| Segurança da execução | Container efêmero, rede restrita | Permissões totais na máquina do dev | Marco 1 (perfis de permissão); containers ficam para o runner de cliente |
| Credencial do agente | API key do cliente no executor | Login de quem roda o `claude` | Marco 1 (modo de autenticação visível e configurável) |
| Projeto | Entidade "Projeto (repositório)" com configuração | Só "runner + diretório" | Marco 3 (Projetos) |
| Gates | Testes, lint, reprodução falha → passa | Só o contrato de saída | Marco 3 (gates por comando) |
| Decisões | Entidade com contexto, responsável, prazo | Pausa com motivo | Marco 2 (página de Decisões) e Marco 3 (entidade) |
| Board | Board em tempo real | Mock | Marco 2 |

---

## 2. Marcos

A ordem vai do que destrava mais ao que pode esperar. Cada item vira um plano de
execução próprio quando chegar a vez. Os itens feitos estão marcados com **✓** e
apontam para o ADR que registra as decisões.

### Marco 1 — Runner robusto, paralelo e com ambiente quente

O runner é onde o produto ganha ou perde a premissa de "ambiente quente, sessão
descartável".

1. **✓ Tarefas em paralelo** ([ADR 0006](../adr/0006-runner-paralelo-e-ambiente-quente.md)).
   - Com um worktree por tarefa, tarefas diferentes não dividem diretório: o runner
     passa a executar até `capacity` jobs ao mesmo tempo (um por tarefa).
   - Jobs avulsos continuam serializados no workdir compartilhado.
   - A tela de criação mostra a ocupação do runner.
2. **✓ Preparação do worktree (setup)** (ADR 0006; o comando vem do projeto, ADR 0008).
   - **Comando de setup:** roda uma vez quando o worktree nasce (ex.:
     `mix deps.get && mix compile`, `pnpm install`), antes da primeira etapa.
   - **Clones de cópia:** os diretórios caros do checkout de origem (`deps`, `_build`,
     `node_modules`, `.venv`, configuráveis) são copiados por *copy-on-write*
     (`cp -c` no APFS, `--reflink` no Linux), de modo que a primeira etapa não paga
     instalação.
   - O tempo de "ambiente pronto" é medido e mostrado (meta do discovery §3.1).
3. **✓ Ciclo de vida do worktree** (ADR 0006). A remoção é a pedido; a retenção
   automática fica para os jobs de manutenção (Marco 4).
   - Remover ao concluir ou cancelar, com política configurável: manter por N dias,
     manter os que falharam.
   - Botão "remover worktree" na tarefa.
   - O runner informa o uso de disco.
4. **✓ Entrega confiável de eventos** (ADR 0006; a outbox ainda não sobrevive a um
   restart do runner).
   - Uma *outbox* no runner guarda `job:event`, `job:started` e `job:finished` até o
     `ok` do servidor e reenvia depois de reconectar. O servidor já é idempotente por
     `(job_id, seq)`.
   - Some a lacuna de eventos aceita no ADR 0004.
5. **✓ Limites na execução** (ADR 0006): tempo máximo por etapa (o runner mata o grupo de processos
   ao estourar) e orçamento por etapa, já suportado via `--max-budget-usd`, exposto
   na UI.
6. **✓ Perfis de permissão em vez de permissão total** ([ADR 0009](../adr/0009-permissoes-credencial-e-operacao-do-runner.md)).
   - Por etapa: "somente leitura" (`plan`), "edita arquivos" (`acceptEdits` + Bash
     restrito), "total" (o atual).
   - Listas de ferramentas permitidas e negadas.
   - Triagem, investigação e auditoria não precisam escrever.
7. **✓ Autenticação do agente** (ADR 0009).
   - O runner informa a origem da credencial (o `init` do stream traz `apiKeySource`).
   - Opção de usar `ANTHROPIC_API_KEY` própria do runner, guardada só nele.
   - Aviso quando roda com login pessoal.
8. **✓ Diagnóstico** (ADR 0009; a página do runner mostra o equivalente).
   - `make runner.doctor`: versão do `claude`, autenticação, `git`, raiz e diretórios,
     disco, conectividade.
   - O resultado aparece também na página do runner.
   - ✓ A página do runner lista as últimas execuções que ele terminou (status, duração,
     custo, tokens, cache), cada uma levando à sua auditoria.
9. **✓ Runner como serviço** (ADR 0009; a outbox ainda não sobrevive ao restart).
   - `runner.start` em segundo plano (launchd/systemd), com logs.
   - Reinício automático com reconciliação. A reconciliação já existe; precisa
     sobreviver ao restart sem perder a outbox.

### Marco 2 — Visualização: o "chat" da tarefa

A tarefa deve ser lida como uma conversa entre a pessoa e o pipeline.

1. **✓ Artefatos renderizados** ([ADR 0007](../adr/0007-visualizacao-da-tarefa.md); sem
   destaque de sintaxe por ora): Markdown com títulos, listas, tabelas e blocos de código
   com destaque de sintaxe, sanitizado. A opção natural é `mdex`, dependência opcional
   do Petal (`Chat.markdown`). Alternância "renderizado / texto".
2. **✓ O que mudou no diretório (git local, sem GitHub)** (ADR 0007; um diretório sem
   git ainda não tem a medida).
   - Ao fim de cada etapa, o runner envia `git diff --stat` e o patch (com limite)
     contra o início da tarefa e contra a etapa anterior.
   - A tela mostra os arquivos alterados e o diff por etapa.
   - Num diretório sem git: só os arquivos novos e modificados.
3. **✓ Linha do tempo rica** (ADR 0007; faltam o agrupamento, os tokens por turno e os
   filtros).
   - Ferramentas mostradas pelo tipo: o comando do Bash com a saída colapsável, o Edit
     como diff, o Read como caminho, as buscas com contagem.
   - Pensamento oculto, agrupamento de chamadas consecutivas, custo e tokens por turno,
     filtros por tipo.
4. **✓ Texto do agente em tempo real** ([ADR 0010](../adr/0010-conversa-com-a-tarefa.md)): `--include-partial-messages` para ver a resposta
   sendo escrita, com limite de frequência no envio.
5. **✓ Conversa contínua** (ADR 0010).
   - Além das decisões em pausa, a pessoa pode a qualquer momento:
     - **mandar uma instrução**, aplicada na próxima tentativa ou etapa;
     - **pausar depois desta etapa**;
     - **refazer uma etapa anterior**, o que invalida as seguintes.
   - Cada intervenção aparece na linha da tarefa como uma mensagem.
6. **✓ Board real** (ADR 0007).
   - Tarefas por estado e por etapa atual, ao vivo, no lugar do mock.
   - Filtros por pipeline, runner, diretório e pessoa.
7. **✓ Página de Decisões** (ADR 0007).
   - O que espera alguém, em todo o workspace, com o motivo e a ação direta.
   - Contador no menu, que já existe e hoje é fixo.
8. **✓ Notificações** (ADR 0010): toast ao vivo e notificação do navegador quando uma tarefa pausa ou
   termina.
9. **✓ Ações sobre tarefas** (ADR 0010): reexecutar (nova tarefa com o mesmo pedido), duplicar com
   outro pipeline ou diretório, buscar no histórico.
10. **Decidido no ADR 0010: as execuções avulsas continuam.** **Execuções avulsas** viram uma tarefa com o pipeline "Prompt único", para haver um
    só lugar de acompanhar trabalho. A tela "Execuções" passa a ser só a visão técnica
    de jobs.
11. **✓ Página do runner** (ADR 0010): diretórios, jobs na fila e em execução, versão do `claude`,
    autenticação, disco e worktrees.

### Marco 3 — Motor de pipeline poderoso

1. **✓ Projetos** ([ADR 0008](../adr/0008-projetos-gates-e-feedback.md)).
   - Um projeto do workspace aponta para um diretório (por nome, valendo em qualquer
     runner que o ofereça).
   - Guarda as configurações: comando de setup, de teste e de lint, diretórios a
     clonar para o worktree, notas de contexto.
   - Os prompts usam `{{projeto.*}}`.
2. **✓ Gates por comando** (ADR 0008).
   - Depois da etapa, o runner roda os comandos do gate no worktree, com a expectativa
     de passar ou falhar. Exemplos: "o teste de reprodução **falha**", "a suíte
     **passa** depois da correção".
   - A saída do comando entra como artefato e no feedback da retentativa.
3. **✓ Regras sobre a saída estruturada** (ADR 0008; por ora só pausam).
   - Condições declarativas que pausam ou desviam. Exemplo: `bem_definida == false` →
     pausa; `risco == "alto"` → aprovação humana.
4. **✓ Retentativa com feedback** (ADR 0008): a nova tentativa recebe o erro, a saída do gate e o
   resumo da tentativa anterior, em vez de repetir o mesmo prompt.
5. **✓ Decisão como entidade** ([ADR 0011](../adr/0011-decisoes-contexto-orcamento-e-portabilidade.md); responsável e prazo ficam para o Marco 4).
   - Pergunta, opções propostas pelo agente (o schema pode trazer `opcoes`), responsável
     sugerido, prazo e histórico.
   - A resposta vira artefato e entra no contexto da etapa seguinte.
6. **✓ Contexto e agentes por pipeline** (ADR 0011).
   - Instruções de sistema do pipeline (`--append-system-prompt`).
   - Etapa associada a um subagente ou skill do repositório (`--agent`) ou a agentes
     definidos no control plane (`--agents`).
   - Servidores MCP por pipeline (`--mcp-config`) para etapas de análise. Exemplo: um
     pipeline de investigação com Grafana.
7. **✓ Orçamento e limites por tarefa** (ADR 0011; limite por workspace fica para o Marco 4): soma de custo com teto e tarefas simultâneas por
   workspace e por runner. Ao estourar, a tarefa pausa em vez de morrer.
8. **✓ Mais templates** (ADR 0011): feature, refactor, revisão de código, investigação de
   produção/métricas (sem alterar código), atualização de dependência.
9. **✓ Importar e exportar pipelines (YAML)** (ADR 0011), o que prepara a opção futura de o repo
   sobrescrever o pipeline.
10. **Adiado no ADR 0011.** **Etapas em paralelo (fan-out)**, por exemplo auditorias independentes que rodam
    juntas e se consolidam numa etapa seguinte. Este é o item mais distante deste
    marco.

### Marco 4 — Uso, custos e operação

1. **✓ Uso e limites** ([ADR 0012](../adr/0012-uso-papeis-auditoria-e-segredos.md)) (a página do menu, hoje placeholder): custo, tokens e tempo por
   tarefa, etapa, pipeline, runner e pessoa ao longo do tempo. Retentativas e decisões
   por etapa (métricas do discovery §6.1).
2. **✓ Papéis no workspace** (ADR 0012): quem cria e edita pipelines, aprova runners, cancela tarefas
   de outros.
3. **✓ Auditoria** (ADR 0012): quem fez o quê (criou, decidiu, cancelou, editou o pipeline), com
   retenção.
4. **✓ Jobs de manutenção** (ADR 0012; um processo periódico em vez do Oban):
   - expirar autorizações de device flow;
   - detectar tarefas paradas (runner offline com tarefa em execução);
   - limpar eventos pela política de retenção;
   - rate limit no device flow.
5. **✓ Alertas** (ADR 0012): tarefa parada, runner offline com trabalho, custo acima do esperado.
6. **✓ Segredos por workspace** (ADR 0012) entregues ao runner por job (ex.: credenciais de um MCP),
   nunca persistidos no runner.

### Marco 5 — Distribuição

1. **✓ Release do runner com `cp-runner`, instalação em um comando**
   ([ADR 0013](../adr/0013-distribuicao-e-entrega-no-git.md); o binário único via
   Burrito veio depois, no [ADR 0014](../adr/0014-pendencias-do-roadmap.md)).
2. **✓ Deploy do control plane** (ADR 0013): release, migrations, `PHX_HOST` e TLS
   para o WebSocket.
3. **✓ Guia de instalação e de primeiro pipeline** ([`guias/instalacao.md`](../guias/instalacao.md)).

### Marco 6 — Integração com git e GitHub (por último)

O que o plano original chama de "PR como canvas":

1. **✓ Entrega determinística no runner** (ADR 0013): commit dos artefatos e mudanças por etapa, push do
   branch da tarefa, PR em rascunho aberto no início e atualizado a cada etapa,
   marcado como pronto no fim.
2. **✓ Issue do GitHub como origem da tarefa, pela URL** (ADR 0013; o webhook por
   label fica para depois).
   Issue do GitHub como origem da tarefa (URL, depois webhook por label), com decisões
   refletidas como comentários.
3. **✓ Credenciais: o `gh` do dev** (ADR 0013; o GitHub App fica para depois).
   Credenciais: o `gh` do dev para o runner local; GitHub App com token por tarefa para
   runners de cliente.

---

## 3. Recomendação de ordem

1. **Marco 1, itens 1–4** (paralelismo, setup, ambiente quente, ciclo de vida do
   worktree, entrega confiável). Isso é o que torna o uso diário viável: hoje a
   primeira etapa de cada tarefa paga instalação, e uma tarefa trava o runner.
2. **Marco 2, itens 1–3 e 6–7** (Markdown, diff local, linha do tempo rica, board e
   Decisões). É o que torna o resultado legível e tira os mocks.
3. **Marco 3, itens 1–4** (projetos, gates por comando, regras e retentativa com
   feedback): o salto de "executa prompts em sequência" para "pipeline com garantias".
4. O restante do Marco 1 (perfis de permissão, autenticação, doctor, serviço) entra
   junto com o Marco 2 ou 3, conforme a necessidade.
5. Marcos 4 e 5, depois o 6.

## 4. Questões em aberto

1. **✓ Respondida no ADR 0006: tarefas no mesmo repositório rodam em paralelo.**
   **Paralelismo e o mesmo diretório:** duas tarefas no mesmo repositório em worktrees
   diferentes compartilham serviços locais (banco de teste, portas). Precisamos de
   isolamento por tarefa, como um banco ou schema por tarefa (discovery §3.1), ou de
   uma trava por diretório?
2. **✓ Respondida no ADR 0006: detecção automática agora, configuração do projeto
   depois.** **Clones de cópia:** quais diretórios copiar é configuração do projeto ou detecção
   automática por toolchain?
3. **✓ Respondida no ADR 0010: espera a etapa terminar.** **Conversa contínua:** uma instrução no meio de uma etapa em execução cancela e refaz
   a etapa ou espera ela terminar?
4. **✓ Respondida no ADR 0007: `mdex` no servidor.** **Markdown:** `mdex` (NIF em Rust, a mesma escolha do Petal) ou renderização no
   cliente?

## 5. O que ficou para depois

As pendências deixadas pelos marcos foram resolvidas no
[ADR 0014](../adr/0014-pendencias-do-roadmap.md):

- etapas em paralelo;
- webhook do GitHub por label;
- outbox que sobrevive a restart;
- destaque de sintaxe;
- tokens, agrupamento e filtros na linha do tempo;
- responsável e prazo das decisões;
- limite de tarefas por workspace;
- mudanças em diretório sem git;
- `gh` no `doctor`;
- binário único do runner (Burrito).

Continua pendente:

| Item | Por quê |
|---|---|
| GitHub App com token por tarefa | exige registrar e instalar um app no GitHub; até lá, o `gh` de quem roda o runner |
