# Telas (e2e)

A tarefa mudou telas: o questionário de decisão (`QuestionnaireLive`, `QuestionnaireComponents`), a página da tarefa, a página de Decisões e a de Propostas.

## e2e
`make e2e` terminou com exit 0: 20 specs passaram, incluindo os três de `decision-questionnaire.spec.ts`.

## Screenshots conferidas
Rodei `make e2e.shots FILE=tests/decision-questionnaire.spec.ts` e abri as versões clara e escura (`-dark`) dos estados abaixo.

- **Tarefa bloqueada com perguntas:** aviso amarelo, contador "0 de 2 respondidas", cartões de opção com selo "recomendada", campo "Outro", "Ver exemplo", botões de ação e "Decidir sem responder". Contraste, alinhamento e tema escuro estão bons.
- **Versão estreita (mobile):** as opções empilham e os botões ocupam a largura toda. O placeholder do campo "Outro" fica cortado ("Responda com suas p…"). É só o placeholder, não afeta o uso, e não mudei nada.
- **Revisão das respostas:** progresso "2 de 2", resumo das respostas, "Voltar" e "Confirmar".
- **Histórico:** tentativa 1 bloqueada, tentativa 2 aprovada, "Respostas da pessoa" e "Decisões tomadas".
- **Falha analisada pelo agente:** aviso de falha, caixa "Diagnóstico do agente" e pergunta de correção. O tema escuro está legível.
- **Página de Decisões:** mesmo questionário, seletor "Quem decide", botão "Sugerir com IA" e instruções opcionais. Está consistente com a página da tarefa.

Os toasts aparecem sobrepostos a parte do conteúdo nas capturas, porque são transitórios. Não tem relação com esta tarefa.

## Ajustes
Nenhum código mudou nesta etapa, então não houve commit nem novo `make ci.quick`.
