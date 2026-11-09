# 0053 — Qualidade das entregas: o desfecho do PR e o commit humano

- **Status:** aceita
- **Data:** 09/11/2026
- **Relacionadas:** [ADR 0012](0012-uso-papeis-auditoria-e-segredos.md), [ADR 0024](0024-resumo-da-execucao-e-metricas-do-agente.md), [ADR 0045](0045-merge-automatico-do-pr.md)

## Contexto

O Uso mostrava quanto o trabalho dos agentes custou, mas não se ele foi bom. O plano
(`docs/plano/01-visao-arquitetura.md` §9, `docs/plano/02-contexto-discovery.md` §6.1) pede
a taxa de PRs aceitos sem alteração e o retrabalho por etapa.

Faltava o que medir:

- `Task.finished_at` muda a cada correção, e `Task.merge_fixes` é zerado ao tentar o merge
  de novo. Nenhum dos dois serve de histórico.
- O PR mergeado só deixava `issue_feedback["merged"]`, sem data. O PR fechado sem merge
  era ignorado.
- O runner commita com a identidade git da máquina da pessoa. Pelo autor do commit não dá
  para saber se foi o pipeline ou a pessoa.
- Uma correção (`Decision` `:correct`) não dizia quem a pediu.

## Decisões

1. **Um desfecho por tarefa, numa tabela própria** (`integration_pr_outcomes`,
   `PipeMaestro.Integrations.PrOutcome`). As colunas não ficam em `tasks` porque a tarefa é
   reescrita a cada mudança, e um campo cumulativo ali corre o risco de ser zerado, como
   `merge_fixes`. Quem escreve é `PipeMaestro.Integrations.PrOutcomes`; o `Usage` só lê.
   - `ready_at` é a primeira vez que a tarefa terminou `succeeded` com `pr_url` num
     repositório vinculado, e nunca muda. É gravado em `Tasks.finish/2` e em
     `Feedback.write_pr`, porque o PR do modo `control_plane` pode nascer depois do fim
     da tarefa.
   - O estado (`open`, `merged`, `closed`), com `merged_at` e `closed_at` do host quando
     ele manda a data. Só um desfecho aberto muda, então o mesmo evento repetido não altera
     nada.
   - `review_rounds` conta os reviews que pediram mudanças e viraram "Correção N". Cada
     review conta uma vez (`review_keys`: o id do review no GitHub; no Forgejo, o id da
     entrega original, o mesmo num replay). O contador nunca é zerado. O mesmo review
     processado de novo não abre uma segunda correção.
   - A classificação é calculada, nunca guardada:
     - **aceito sem alteração**: mergeado, sem commit humano e sem rodada de review;
     - **aceito com alteração**: mergeado, com pelo menos um dos dois;
     - **fechado** sem integrar;
     - **em aberto**.
2. **Commit humano por SHA e pela posição na lista do PR.** A plataforma lê os commits do
   PR (`Provider.pr_commits/3`, do mais antigo para o mais novo) e compara com o
   `Task.head_sha`, o último commit que o pipeline empurrou:
   - **head nova na lista:** quando o PR tem um `head_sha` ainda não considerado
     (`observed_head`), os commits até ele, inclusive, são do pipeline, e os que vêm
     depois são de uma pessoa;
   - **head já considerada:** fora disso, todo commit que não é do pipeline é de uma pessoa;
   - **commit de merge:** um commit com mais de um pai nunca conta. É o "Update branch" do
     host trazendo a base, e não muda o trabalho entregue;
   - **conjuntos:** só crescem, então ler duas vezes não muda nada.

   A leitura acontece depois de cada mudança da tarefa (`FeedbackWorker`, na entrega e ao
   começar uma etapa nova), no merge e no fechamento (na hora, em `Conversation`) e no
   `Reconciler`. O `Reconciler` também consulta `get_pr/3` dos PRs abertos para pegar o
   merge que o webhook perdeu. Uma falha do host fica em `commits_error` e é tentada de
   novo; nada disso para a tarefa.
3. **`Decision.origin`** diz quem pediu a correção: `:person` (tela ou comando),
   `:review` ou `:auto_merge`. As correções antigas foram preenchidas assim: `auto_merge`
   onde `decided_via` é "merge automático", e `person` no resto.
4. **Pausas vêm das decisões.** Toda pausa (`awaiting_decision`) termina numa decisão
   `:retry`, `:advance` ou `:cancel` com o índice da etapa, ou ainda está aberta. Pausas
   por etapa são essas decisões mais as tarefas esperando ali agora. Não há tabela nova.
5. **Períodos.**
   - Os desfechos contam pelo `ready_at`.
   - O retrabalho e as pausas contam pela data de cada evento (`stage_runs`, `decisions`),
     porque valem para toda tarefa, entregue em PR ou não.
   - O tempo até o merge é a mediana, que um PR esquecido não distorce.
   - A taxa ao longo do tempo é por semana, porque com poucos PRs por dia ela oscilaria
     entre 0% e 100%.
6. **A aba Qualidade** (`?aba=qualidade`) segue os filtros da barra do Uso, que ganhou o
   de projeto.

## Limitações aceitas

- Um commit humano empurrado enquanto uma etapa roda, e que o runner incorpora antes do
  seu push, fica antes do `head_sha` e conta como do pipeline.
- Num force-push, os SHAs reescritos somem do PR mas continuam contados.
- O GitHub lista no máximo 250 commits por PR.
- Numa conexão com `api_mode` `runner`, a plataforma não chama o host
  (`commits_tracked = false`). A classificação usa só os reviews, e a aba mostra quantos
  PRs ficaram sem leitura de commits.
- Uma pausa encerrada por "refazer a partir daqui", sem decisão, não entra na contagem.
- As tarefas anteriores a esta mudança não têm desfecho, e os reviews antigos não se
  distinguem de correções pedidas por uma pessoa.

## Consequências

- O Uso mostra se o trabalho foi aceito, além do que custou. As correções e as pausas
  apontam as etapas que precisam de prompt ou gate melhores.
- Cada PR em aberto custa uma leitura de commits por mudança da tarefa e uma consulta por
  passagem do `Reconciler`, até ser integrado ou fechado.
