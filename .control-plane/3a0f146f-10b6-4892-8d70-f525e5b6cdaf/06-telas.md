# 06 — Telas (e2e)

## O que mudou em tela

- Página da proposta de tarefa (`proposal_live/show.ex`): o card "Perguntas do agente" com o questionário respondível.
- `QuestionnaireLive`: ações e rótulo de envio configuráveis. As telas de decisão usam os padrões e não mudaram.
- Specs: `e2e/tests/agent-proposals.spec.ts` (Flow F) e `e2e/pages/ProposalPage.ts`.

## Verificação

- `make e2e.typecheck`: passou.
- `make e2e.shots FILE=tests/agent-proposals.spec.ts`: capturas em claro e escuro, abertas e auditadas.
- `make e2e` (suíte inteira, uma vez): saiu 0, 37 testes passaram.

## Capturas conferidas, claro e escuro

Cópias em `$CP_FILES_DIR/telas/`.

- **Proposta não pronta com o motivo do auto-approve** (`06-task-proposal-auto-skipped`): o motivo lista a pergunta numerada, com as opções e "(recomendada)", legível no alerta amarelo. Contraste bom nos dois temas.
- **Questionário respondível** (`07-task-proposal-questions`):
  - card de largura total, com título, descrição, progresso "0 de 1 respondidas", a pergunta com a etiqueta "Carga";
  - opções em cards lado a lado, a recomendada com o selo verde, "Ver exemplo" para o preview e o campo "Outro";
  - nada cortado ou sobreposto, e o tema escuro mantém o contraste do selo e da barra de progresso.
- **Nova rodada virando a tarefa** (`08-task-proposal-answered`): a entrada da tarefa traz o critério com a resposta ("100 logins simultâneos, como a pessoa respondeu").

## Ajustes

Nenhum foi necessário. O botão "Revisar e criar a tarefa" aparece acima do questionário, dentro do card da tarefa proposta, e foi mantido assim porque a ação principal da tela continua sendo criar a tarefa.

Só as telas do questionário abaixo da dobra (revisão e botões de envio) não aparecem nas capturas; elas são cobertas pelo Flow F, que as exercita.
