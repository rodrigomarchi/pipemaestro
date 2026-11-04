# Implementação: Tela melhor de decisão

O plano (`01-plano.md`) está implementado. Os testes da etapa 2 passam sem terem sido
enfraquecidos.

- **`make ci.quick`:** exit 0.
- **`make ci`:** exit 0, com Dialyzer sem erros.
- **`make e2e`:** 20 de 20 specs passaram.
- **`make e2e.shots`** do spec novo: capturas conferidas uma a uma, claro e escuro, larga
  e estreita.

## O que mudou, por app

### `pipe_maestro` (domínio)

- **`Tasks.Questionnaire` (novo).** Módulo puro com:
  - `normalize/1`: limites, truncagens e a recomendada primeiro;
  - `from_options/1` e `for_run/1`;
  - `validate_answers/2` e `validate_partial/2`, para o "Avançar mesmo assim";
  - `to_markdown/2`, `answer_text/1`, `answered?/1`, `choices/1` e `other/1`.
- **`Pipelines.Prompt`.**
  - `perguntas` entra no schema base (`questions_schema/0`) e `opcoes` fica "obsoleto",
    sem `if/then`.
  - O cabeçalho fixo explica que `AskUserQuestion` não existe e ensina a perguntar.
  - `build/2` ganha a seção "Respostas da pessoa às suas perguntas", depois do feedback.
- **`Pipelines.Templates`.** O template de especificação pede `perguntas` em vez de
  `opcoes`.
- **Migração `20261110090000_add_decision_questionnaire`.** Adiciona:
  - em `tasks`: `decision_questionnaire` e `decision_analysis_job_id`, que referencia
    `jobs` com `nilify_all`;
  - em `decisions`: `questions` e `answers`;
  - em `stage_runs`: `answers`.

  Todas as colunas aceitam nulo e não há backfill. `Task`, `Decision` e `StageRun` ganharam
  os campos, os tipos e o moduledoc.
- **`Proposals.AnalysisKind` (novo).** Tipo `"analysis"`, com:
  - o contexto do `DecisionKind`;
  - `directory` só quando a tarefa é git e o runner anuncia `scratch`;
  - US$ 1 e 10 minutos de teto;
  - `result/2` passando por `normalize/1`;
  - `current?/2`.

  Fica registrado em `Proposals.kinds/0`.
- **`Jobs`.** `finished/1` chama `Tasks.analysis_finished/1` para jobs de proposta
  `"analysis"`. Isso vale para o fim normal, o cancelamento de job na fila e a reconciliação
  de jobs perdidos. `Maintenance` não encerra jobs, então não muda.
- **`Tasks`.**
  - **Pausa.** `await/3` grava o questionário de um bloqueio (`for_run/1`). Num grupo, junta
    as perguntas das etapas bloqueadas e marca cada uma com `"etapa"`, para a tela.
  - **Análise.** Um bloqueio sem nada a perguntar, ou as tentativas esgotadas, pedem
    `request_analysis/1` em nome do criador da tarefa. Uma recusa vai para o `Logger`.
    Pausas por regra, por orçamento ou a pedido não ganham questionário nem análise.
  - **Fim da análise.** `analysis_finished/1` grava o questionário com origem `analise` só
    quando a análise ainda vale para a pausa atual (mesmo `decision_analysis_job_id` e
    `current?/2`). Em todo caso, notifica.
  - **`questionnaire/1`.** Devolve `%{questionnaire, analysis: :none | :running | :failed}`.
  - **`answer/4`.** Valida as respostas e repete a etapa como `retry_stage`. O `Decision`
    guarda `questions` e `answers`, e o novo `StageRun.answers` chega ao prompt.
  - **`advance/3`.** Aceita `answers:` parciais, e nenhuma resposta conta como ausência de
    respostas.
  - **Concorrência.** `decide` reivindica a pausa com um `UPDATE … WHERE status =
    awaiting_decision`. Preferi isso a `FOR UPDATE` numa transação porque o job é entregue
    ao runner na hora em que é criado, e dentro de uma transação aberta o runner poderia
    responder antes do commit.
  - **Cancelamento da análise.** Decidir, cancelar ou `redo_from` cancelam a análise ativa.
    `start_stage` e `finish` limpam o questionário e a análise.
  - **Issue e auditoria.** O comentário da issue traz as perguntas e as respostas, e a
    auditoria `task.decided` ganha `"answered" => true`.

### `pipe_maestro_web`

- **`QuestionnaireComponents` (novo).** Mostra o questionário em modo leitura: diagnóstico,
  perguntas, opções, preview e respostas. Também traz `analysis_state/1` ("analisando…" e
  "a análise não ficou pronta"), `answer_list/1` e `decode_answers/1`.
- **`QuestionnaireLive` (novo, LiveComponent).** Guarda as respostas em andamento enquanto o
  questionário for o mesmo, além do progresso (badge e `<.progress>`), da revisão e do
  "Outro".
  - As opções são cartões `<label>` com radio ou checkbox `sr-only` e `has-[:checked]:`.
  - O `data-testid` da opção fica no `label` clicável.
- **`TaskLive.Show`.**
  - **Painel.** Mostra o motivo, o estado da análise e o questionário. "Sugerir com IA" e a
    decisão manual ficam no `<details>` "Decidir sem responder" (`decision-manual` e
    `decision-manual-toggle`). Ele vem aberto quando não há nada a responder nem análise
    em curso.
  - **Histórico e tentativa.** O histórico mostra pergunta → resposta
    (`task-decision-answers-<n>`), e a tentativa mostra as respostas que recebeu
    (`stage-run-answers-<key>-<n>`).
  - **Outra sessão.** O flash "Outra pessoa respondeu esta decisão." aparece quando a tarefa
    sai de `awaiting_decision` por fora.
- **`DecisionsLive`.** Usa o mesmo componente por tarefa, com ids terminados em
  `-<task_id>`, e o estado da análise.
- **`ProposalLive.Show`.** Lê a proposta `analysis` (diagnóstico e perguntas em modo
  leitura) e tem o link "Responder na tarefa". Sem isso, abrir uma análise quebraria em
  `assign_review/2`.

### `pipe_maestro_runner`

- **Código: nada muda.**
- **`test/support/fake_claude`.**
  - O marcador `[perguntas]` gera duas perguntas: uma simples, com preview na recomendada,
    e uma múltipla.
  - O tipo `analysis` responde com a recomendada "Tentar sem falha".
  - `[falha]` passa a ser ignorado quando o prompt tem "Tentar sem falha" ou quando o job é
    a própria análise, cujo prompt repete o da tarefa.
- **`job_runner_test.exs`.** Ganhou o caso `[perguntas]`.

### `pipe_maestro_protocol`

Não muda. O schema maior viaja dentro do `output_schema`, como antes.

## Desvios do plano (e por quê)

- **Os botões do questionário falam direto com a LiveView.** "Confirmar", "Avançar mesmo
  assim" e "Cancelar a tarefa" disparam o evento `"questionnaire"` na LiveView mãe, com
  `phx-value-answers` em JSON, em vez de `send(self(), {:questionnaire, …})`.
  - **Por quê:** com o `send`, a decisão rodava depois de o clique terminar, e a outra
    sessão do teste A10 ainda não tinha recebido a mudança.
  - **Segurança:** o domínio valida as respostas, então um JSON adulterado é recusado.
- **Reivindicação condicional em vez de `FOR UPDATE`.** O motivo está em `Tasks` acima.
- **O `<details>` da decisão manual tem `id` estável e
  `phx-mounted={JS.ignore_attributes(["open"])}`.** Sem isso, cada atualização ao vivo
  (por exemplo, o fim da análise) fechava o bloco que a pessoa tinha aberto. O e2e pegou o
  problema.

## Testes ajustados (e por quê)

- **`proposals_test.exs` ("is a kind of its own").** `assert [job] = …; assert job.id ==
  job.id` era uma tautologia e gerava aviso de variável não usada, o que quebraria
  `--warnings-as-errors`. Agora compara o job listado com o job da análise.
- **`pipelines_test.exs` ("always requires status and resumo").** A lista exata de chaves do
  schema passou a incluir `perguntas`, que é a mudança pedida.
- **`e2e/tests/agent-proposals.spec.ts`:**
  - abre "Decidir sem responder" (`tasks.openManualDecision()`) antes de "Sugerir com IA",
    porque o botão agora fica no bloco recolhido enquanto a análise roda;
  - a lista de Propostas passa a ter 4 itens, porque a análise automática do bloqueio
    também é uma proposta.
- **`e2e/tests/decision-questionnaire.spec.ts`:**
  - os fluxos deixam de ser `[todo]`;
  - ganhou a captura estreita (390 px) `questionnaire-blocked-narrow`.
- **Teste novo em `proposal_live_test.exs`.** Uma análise é lida na página da proposta e
  marcada como vencida depois de uma decisão.

## Como verificar

```sh
make ci.quick > /tmp/ciq.log 2>&1; echo $?          # 0
make ci > /tmp/ci.log 2>&1; echo $?                 # 0 (Dialyzer)
make e2e > /tmp/e2e.log 2>&1; echo $?               # 0, 20 passed
make e2e.shots FILE=tests/decision-questionnaire.spec.ts
# capturas em e2e/screenshots/decision-questionnaire/
```

Pontos para conferir nas capturas:

- **Bloqueio:** a recomendada vem primeiro, com o selo, e o "Ver exemplo" fica abaixo
  dela.
- **Revisão:** pergunta → resposta.
- **Falha:** o diagnóstico fica legível no escuro, porque o Markdown herda a cor do
  alerta.
- **Histórico:** a tentativa 2 e "Decisões tomadas" trazem as respostas.
- **Página Decisões:** o questionário aparece por tarefa.
- **Tela estreita:** uma coluna, com botões de largura total.

## Observações

- **Cabeçalho a 390 px.** As ações do cabeçalho da tarefa (Tarefas, Duplicar, Cancelar)
  transbordam a largura e deixam uma faixa branca à direita na captura estreita. Isso já
  acontecia antes desta tarefa e não afeta o questionário. Fica como sugestão para uma
  tarefa de layout móvel.
- **Escopo da documentação.** A documentação (ADR 0028, spec da máquina de estados, ADR
  0022 e guia de UI) foi escrita nesta etapa para fechar o bloco. A etapa de documentação
  pode revisá-la.
- **O que rodou depois do último e2e.** Os dois últimos commits mudam só a documentação e
  a forma de `validate_answers`/`validate_partial`: um helper comum e specs mais largos. Os
  dois passaram por `make ci`.
