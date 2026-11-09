# 0029 — Questionário de decisão

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

Uma tarefa em `awaiting_decision` mostrava um parágrafo (`decision_reason`) e, às vezes,
botões com as frases de `opcoes` da saída da etapa. A próxima tentativa recebia só
`"Decisão: <frase>"` junto das instruções. Quando a etapa falhava (tentativas esgotadas,
gate reprovado, erro do CLI), a pessoa tinha de ler o erro e escrever instruções sozinha,
ou pedir "Sugerir com IA" ([ADR 0022](0022-propostas-do-agente-como-mecanismo-geral.md)).

O agente roda com `claude -p` (ADR [0011](0011-decisoes-contexto-orcamento-e-portabilidade.md)).
Verificado com o CLI 2.1.318 e as flags do runner: a ferramenta `AskUserQuestion` não
existe nesse modo. Nada trava; o agente só não tem como perguntar, e a pergunta escrita
no texto final se perde.

## Decisão

- **Perguntas estruturadas na saída.** O schema base das etapas
  (`Prompt.questions_schema/0`) ganha `perguntas`: de 1 a 4 perguntas, cada uma com
  `titulo` (até 12 caracteres), `pergunta` (termina em "?"), `multipla` e de 2 a 4 opções
  (`rotulo`, `descricao`, `recomendada`, `preview` opcional). "Outro", com texto livre, é
  sempre oferecido na tela e não está no dado.
- **Os limites são da plataforma, não do schema.** O schema não usa `if/then` para exigir
  `perguntas` quando `status` é `bloqueado`: não se sabe se o `--json-schema` do CLI aceita
  essas construções, e um schema recusado derrubaria todas as etapas.
  `Tasks.Questionnaire.normalize/1` lê a resposta de forma defensiva: recusa o que fere os
  limites, corta o título e os rótulos longos e põe a recomendada primeiro.
- **O cabeçalho fixo do prompt ensina a perguntar** e diz que `AskUserQuestion` não existe:
  toda pergunta vai em `perguntas`, com `status: "bloqueado"`.
- **Convivência com `opcoes`.** O campo continua no schema, marcado "obsoleto". Um bloqueio
  só com `opcoes` vira uma pergunta única gerada pela plataforma ("Como a etapa deve
  seguir?"). Um job despachado antes do deploy segue o mesmo caminho.
- **Análise automática na falha.** Uma pausa por falha, ou um bloqueio sem nada a
  perguntar, pede sozinha uma proposta do tipo `analysis` (`Proposals.AnalysisKind`), em
  nome de quem criou a tarefa:
  - lê o mesmo contexto do tipo `decision` e, se o runner anuncia `scratch`, o código num
    worktree descartável; sem ele, só o contexto;
  - responde um diagnóstico e perguntas no mesmo formato, que viram o questionário da
    pausa (`decision_questionnaire`, origem `analise`);
  - teto de US$ 1 e 10 minutos, menor que o de `decision`, porque ninguém pediu;
  - sem segredos, como toda proposta;
  - vale só para a sua pausa (`decision_analysis_job_id` e `current?/2`): decidir a
    cancela, e uma que termina depois é ignorada;
  - se falha, é cancelada ou responde sem perguntas válidas, a tela diz que a análise não
    ficou pronta. A decisão manual está disponível o tempo todo.
  Uma pausa por regra, por orçamento ou a pedido não tem questionário nem análise.
- **Respostas.** "Responder e continuar" (`Tasks.answer/4`) exige todas as perguntas
  respondidas. O `Decision` guarda `questions` e `answers`. A nova tentativa as grava no
  `StageRun` (`answers`) e as recebe numa seção própria do prompt ("Respostas da pessoa às
  suas perguntas"). Elas também vão para o comentário da issue. "Avançar mesmo assim"
  aceita respostas parciais e as entrega à etapa seguinte.
- **Uma decisão por pausa.** A decisão reivindica a pausa num `UPDATE` condicional
  (`status = awaiting_decision`). De duas pessoas decidindo ao mesmo tempo, só uma grava a
  decisão e o job.
- **A tela é um componente só.** `PipeMaestroWeb.QuestionnaireLive` (respostas em
  andamento, progresso, revisão) aparece no painel da tarefa e na página Decisões.
  `QuestionnaireComponents` mostra o questionário em modo leitura, na página da proposta.
  Os botões de envio mandam o evento direto à LiveView, que decide enquanto trata o
  clique; assim a outra sessão já recebe a mudança quando o clique termina.

## Consequências

- O protocolo não muda: o `output_schema` do job é um mapa livre, e um runner antigo
  repassa o schema maior ao `--json-schema` como qualquer outro.
- Cada pausa por falha custa até US$ 1 de análise. O pipeline a desliga com
  `auto_analysis` (switch "Analisar falhas com IA", ligado por padrão): desligado, a pausa
  leva só o motivo e a decisão manual, e "Sugerir com IA" segue disponível. A tarefa
  guarda o valor no retrato do pipeline (`pipeline_context`); um retrato sem a chave conta
  como ligado. Um bloqueio com perguntas do agente mostra o questionário dele de qualquer
  forma.
- As análises aparecem na página Propostas, filtráveis pelo tipo, e a página da proposta
  só as lê: a resposta acontece na tarefa.
- Decisões antigas, sem `questions`/`answers`, continuam lidas pelo formato de antes.
- As `perguntas` do tipo `task` continuam uma lista de frases; o componente aceita o
  formato estruturado para ser reaproveitado quando migrarem.
