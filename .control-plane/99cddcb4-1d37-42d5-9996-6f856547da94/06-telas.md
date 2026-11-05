# Telas (e2e)

A tarefa mudou telas (`task_live/index`, `proposal_live/show`, `audit_live`, `task_live/show`) e o spec `e2e/tests/agent-proposals.spec.ts`.

## Resultado
- `make e2e`: 22 de 22 passaram (código de saída 0).
- `make e2e.shots FILE=tests/agent-proposals.spec.ts`: screenshots claras e `-dark` abertas e conferidas.

## Telas e estados conferidos (claro e escuro)
- **Modal "Escrever tarefa com IA"** (02): seletor de pipeline ("Deixar o agente escolher") e switch "Criar e iniciar a tarefa sem revisão" ligado por padrão, com texto de ajuda. Alinhado com os demais campos, sem texto cortado.
- **Proposta criada automaticamente** (05): selo "Concluído", botão "Abrir a tarefa", pipeline escolhido no cartão "Pronta para rodar?".
- **Proposta não criada automaticamente** (06): alerta de aviso com o motivo e as perguntas, botão "Revisar e criar a tarefa", selo "Ainda não: responda antes".
- **Revisão da proposta** (03) e **formulário da tarefa** (04): inalterados no comportamento; legíveis nas duas versões.

## Ajustes
Nenhum: contraste, alinhamento e consistência com as telas vizinhas e com `docs/guias/ui-petal.md` estão corretos (componentes Petal: `alert`, `button`, switch). Nenhuma mudança de código nesta etapa.
