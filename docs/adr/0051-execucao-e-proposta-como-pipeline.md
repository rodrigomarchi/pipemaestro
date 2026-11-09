# 0051 — A execução e a proposta como pipeline

- **Status:** aceita
- **Data:** 09/11/2026
- **Relacionadas:** [ADR 0049](0049-a-tarefa-e-o-pipeline.md), [ADR 0048](0048-drawer-em-abas.md)

## Contexto

A tarefa virou o seu pipeline ([ADR 0049](0049-a-tarefa-e-o-pipeline.md)): um trilho
vertical em que cada lugar abre um drawer com o que pertence ali. A execução (cinco
abas: Resultado, Resumo, Prompt, Linha do tempo, Auditoria) e a proposta (três:
Proposta, Como o agente trabalhou, Resumo) ainda eram páginas de abas. As três telas
mostram o mesmo fluxo: um pedido entra, o agente trabalha, algo sai. Mesmo assim,
cada uma tinha um formato diferente.

## Decisões

1. **As duas telas são um trilho, como a tarefa.**
   - O card de lugar (`PipelineComponents.place_node/1`) e o trilho (`rail_item/1`)
     são os mesmos nas três telas.
   - Cada lugar abre um drawer, e a URL guarda o lugar aberto (`?no=`).
   - Links antigos com `?aba=` levam ao lugar que guarda aquele conteúdo agora.
2. **Execução:**
   - **Entrada:** o prompt.
   - **Agente:** a linha do tempo e, quando a execução termina, a aba **Auditoria**.
   - **Resultado:** o resultado ou o erro.
   - **Fim:** runner, duração, turnos, custo e o gasto até agora.
   - O link "Execução e auditoria" da tarefa abre o Agente na auditoria.
3. **Proposta:**
   - **Pedido:** o que foi pedido, o diretório, o runner e a issue.
   - **Agente:** a linha do tempo.
   - **Proposta:** a revisão do tipo e a ação.
   - **Pedir de novo com ajustes:** um lugar tracejado, só depois que o agente
     terminou. Substitui o botão do cabeçalho e o modal.
4. **O que importa não fica atrás de um clique.**
   - A revisão abre sozinha quando a proposta fica pronta: ao chegar numa proposta
     já respondida e quando o agente termina. Fechada, continua fechada.
   - O card do Agente acompanha a execução ao vivo: eventos, gasto até agora, tokens,
     ferramentas e a última linha do que o agente está digitando.
5. **Todo drawer fica na página, escondido enquanto fechado.** A linha do tempo é um
   stream e continua crescendo com o drawer fechado.

## Consequências

- Tarefa, execução e proposta se leem do mesmo jeito: o trilho primeiro, os detalhes
  a um clique.
- Na proposta de pipeline, o pipeline proposto e o drawer das etapas dele abrem
  dentro do drawer da proposta.
