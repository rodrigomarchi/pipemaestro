# 0028 — Teto de custo só quando configurado

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

A plataforma decidia sozinha quanto se podia gastar. Cada tipo de proposta do agente
(ADR 0022) fixava um `max_budget_usd` no código, de US$ 2 ou US$ 3, e uma análise grande
era cortada no meio. O agente também propunha tetos: o schema da resposta de pipeline
aceitava `max_task_cost_usd`, e as instruções diziam que "o orçamento" parava a tarefa.
Um pipeline gerado já nascia com teto, sem que ninguém o tivesse pedido.

## Decisão

- **Um teto de custo só existe quando a pessoa o configura**, nos dois campos que já
  existiam: `max_task_cost_usd` no pipeline e `max_budget_usd` na etapa (ADR 0011). Vazio
  é sem limite, e os formulários dizem isso.
- **As propostas do agente rodam sem teto de custo.** O job vai sem `max_budget_usd`, e o
  runner não passa `--max-budget-usd`.
- **O agente nunca propõe nem vê um teto.** O schema e as instruções de pipeline não
  falam em teto; se a resposta trouxer um, o resultado o descarta
  (`Pipelines.Yaml.without_caps/1`). A importação de YAML pela pessoa continua trazendo
  os tetos dela.
- **Uma melhoria preserva o teto atual.** O YAML mostrado ao agente vai sem tetos, e o
  resultado recoloca o teto do pipeline e o de cada etapa cuja `key` continua.
- **O custo continua visível** em Execuções, Propostas, Uso e na auditoria.
- **Os limites de tempo ficam** (`timeout_ms` das propostas, `timeout_minutes` das
  etapas): protegem contra processo travado.

## Consequências

- Uma proposta pode custar mais que antes. É a intenção, e o custo aparece.
- Pipelines que já nasceram com um teto proposto pelo agente o mantêm até a pessoa
  apagá-lo no formulário: um teto salvo é dela, e não há migração de dados.
- O protocolo não muda: `max_budget_usd` já era opcional no `job:assign`, e todo runner
  publicado omite a flag sem ele.
