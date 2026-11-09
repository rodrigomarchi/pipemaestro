# 0050 — O custo próprio de uma sessão retomada

- **Status:** aceita
- **Data:** 09/11/2026
- **Relacionadas:** [ADR 0041](0041-continuar-a-sessao-da-etapa-anterior.md)

## Contexto

Uma etapa com `context: "continue"` retoma a sessão do agente da etapa anterior
(`--resume`, [ADR 0041](0041-continuar-a-sessao-da-etapa-anterior.md)). Um teste direto no
Claude CLI confirmou o que acontece:

- `total_cost_usd` e `modelUsage` do resultado são **da sessão inteira**: incluem o que
  as execuções retomadas já gastaram.
- Os tokens de `usage` são **só da execução**.

Cada job guardava o custo da sessão, e a tarefa somava os jobs. Numa cadeia de etapas
contínuas, o gasto das primeiras era contado de novo em cada etapa seguinte. Uma tarefa
de cerca de US$ 13 mostrava US$ 57; o Uso e o teto de custo da tarefa liam o mesmo
valor inflado.

## Decisão

- **Na plataforma, sem mudar o protocolo nem o runner**
  (`PipeMaestro.Jobs.SessionTotals`, ao fim do job):
  - o job guarda em `session_totals` o custo e o uso por modelo como o CLI reportou;
  - o `cost_usd` e o `model_usage` do job passam a ser esse valor menos o
    `session_totals` do job que ele retomou;
  - o job retomado é o último do workspace que terminou com a sessão em
    `resume_session_id`;
  - um job anterior a esta decisão, sem `session_totals`, entra com o próprio custo,
    que era o da sessão.
- **Só um job que de fato retomou a sessão (`session_resumed: true`) desconta.** O que
  caiu numa sessão nova não desconta nada.
- **Só daqui para a frente.** Os jobs já gravados não são recalculados.

## Consequências

- O custo de cada etapa e o da tarefa são o que cada execução gastou.
- As tarefas que rodaram antes desta decisão continuam com o custo inflado.
