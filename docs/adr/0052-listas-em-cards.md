# 0052 — Listas em cards

- **Status:** aceita
- **Data:** 09/11/2026
- **Relacionadas:** [ADR 0049](0049-a-tarefa-e-o-pipeline.md), [ADR 0051](0051-execucao-e-proposta-como-pipeline.md)

## Contexto

As listagens usavam três formatos diferentes:

- o `<.table>` do Petal;
- listas `<ul class="divide-y">`;
- linhas montadas por cada tela.

Nenhuma tinha tratamento para celular: as tabelas rolavam de lado e as listas só quebravam
linha. As telas de detalhe ganharam o trilho e os cards de lugar
([ADR 0049](0049-a-tarefa-e-o-pipeline.md)), mas as listas continuavam em outro estilo.

## Decisões

1. **Toda listagem de registros é uma coluna de cards** (`PipeMaestroWeb.ListComponents`):
   - `record_list/1` é a lista; `record_card/1`, cada registro;
   - `record_metric/1` é um número do registro; `record_icon/1`, o ícone que abre o card;
     `record_empty/1`, o estado vazio;
   - `load_more/1` traz a próxima página.
2. **Um layout só, no desktop e no celular.**
   - O card põe as métricas à direita quando é largo, por container query, e embaixo antes
     disso.
   - Um card com link é clicável inteiro: o link do título se estende sobre o card. O que é
     interativo dentro dele (ações, formulários, links próprios) fica por cima desse link.
3. **Todo card tem identidade por ícone.** Ele abre com um quadrado de ícone colorido;
   em tarefas e execuções, o ícone e a cor seguem o status. Os fatos (`record_fact/1`) e
   as métricas levam ícones de um vocabulário só, descrito no
   [guia de UI](../guias/ui-petal.md).
4. **Os tons de atenção são os mesmos dos lugares de um pipeline** (`attention_class/1`):
   rodando, aguardando, erro e sucesso.
5. **Continuam em tabela** as matrizes de números (uso por etapa, ferramentas e fontes da
   auditoria) e os logs técnicos do runner, porque ali o que importa é comparar colunas.
6. **Listas longas paginam com "Carregar mais".** Tarefas, execuções, propostas e
   auditoria começam com 30 itens e somam 30 a cada clique. O limite cresce e a lista
   recarrega do topo, então um evento ao vivo recarrega a lista sem perder o que já foi
   carregado.
7. **Os test ids ficam.** O da antiga linha passa para o card.

## Consequências

- As listas ficam iguais entre telas e entre desktop e celular.
- Comparar números de muitos registros lado a lado fica menos direto do que numa tabela,
  e por isso as matrizes de números continuam em tabela.
- Antes, uma lista cortada em 100 ou 200 escondia o resto. Agora tudo se alcança com
  "Carregar mais".
