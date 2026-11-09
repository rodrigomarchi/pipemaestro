# 0049 — A página da tarefa é o pipeline

- **Status:** aceita
- **Data:** 09/11/2026
- **Relacionadas:** [ADR 0046](0046-pagina-da-tarefa-em-fases.md), [ADR 0048](0048-drawer-em-abas.md)

## Contexto

A página da tarefa ([ADR 0046](0046-pagina-da-tarefa-em-fases.md)) tinha seis abas:
Etapas, Resumo, Pedido, Arquivos, Anexos e Decisões. Na aba Etapas, uma coluna à
direita, do lado do pipeline, juntava os alertas do runner, a mensagem, a pausa, a
interrupção e o "Corrigir com um prompt". A correção é um recurso acessório, mas
competia pela atenção com o pipeline, que é a visão principal da plataforma. O resto
da tarefa ficava espalhado em abas, longe do ponto do pipeline a que pertence.

## Decisões

1. **A página é o pipeline, sem abas e sem coluna lateral.** Ele ocupa a largura
   central da página. Acima dele ficam só o banner de decisão pendente e os alertas
   do runner, porque são o que segura a tarefa.
2. **Cada lugar do trilho abre um drawer, e o conteúdo fica onde pertence**
   (`TaskLive.PipelineView`, `TaskLive.NodePanel`). A URL guarda o lugar aberto.
   - **Entrada** (`?no=entrada`): **Pedido** e, depois, **Projeto** (pipeline,
     projeto, runner e diretório, branch, worktree, issue e o retrato do projeto).
   - **Etapa** (`?etapa=<key>`): as tentativas ([ADR 0048](0048-drawer-em-abas.md)).
     A etapa em que a tarefa está também traz a mensagem, a pausa e a interrupção.
   - **Pull request** (`?no=entrega`), quando o pipeline entrega PR: **Arquivos**
     alterados e **Merge** (o link e por que o merge parou).
   - **Fim** (`?no=fim`): **Resumo** (custo contra o teto e andamento) e
     **Anexos**. Sem nó de PR, os **Arquivos** alterados também ficam aqui.
   - **Corrigir com um prompt** (`?no=corrigir`): um lugar tracejado depois do Fim,
     só numa tarefa que terminou. Abre o formulário, e a correção roda como uma
     nova etapa.
   - Cada nó do trilho mostra só fatos leves: a etapa mostra o 📎 com quantos arquivos
     enviou, a entrada mostra o projeto e o pipeline, o PR mostra quantos arquivos
     mudaram e o fim mostra o custo e os anexos.
3. **Uma decisão tomada é um item encadeado no trilho.** Ela aparece logo depois da
   etapa que decidiu. Uma correção aparece antes da etapa que criou. O item diz
   quem decidiu, o quê, quando e por onde; as respostas e as instruções ficam
   recolhidas nele.
4. **Um lugar que deixa de existir fecha.** Quando a correção começa, o drawer de
   correção fecha e sai da URL.

## Consequências

- O pipeline é a tela inteira, e tudo da tarefa se acha nele.
- Links antigos com `?aba=` abrem a página da tarefa sem nenhum drawer.
- Ver a lista completa de decisões pede percorrer o trilho. Não há mais uma aba que
  junte todas.
