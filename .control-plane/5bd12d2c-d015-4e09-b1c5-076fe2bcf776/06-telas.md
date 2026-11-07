# Telas (e2e)

A tarefa mudou telas (`board_live` dividido em abas), então o e2e rodou.

## Resultado
- `make e2e`: 28 testes passando (exit 0).
- `make e2e.shots` em `task-pipeline`, `board-alerts` e `user-session`; screenshots claras e `-dark` abertas e conferidas.

## Telas e estados conferidos
- Visão geral: cartões de métricas, próximas decisões vazias, atividade recente; estado com alertas ("Precisa de atenção") e contador na aba.
- Tarefas: colunas com filtros e colunas vazias.
- Decisões: estado vazio.
- Atividade: lista de tarefas recentes.
- Executores: tabela com status online, contador `online/total` na aba.
- Largura estreita (mobile): abas rolam na horizontal, tabela rola dentro do card.
- Claro e escuro: contraste e alinhamento ok.

## Ajuste
- Aba Executores: a tabela encostava no cabeçalho do card; adicionado `class="mt-4"` na tabela (`runners_tab.ex`). Shots refeitos: ok.
