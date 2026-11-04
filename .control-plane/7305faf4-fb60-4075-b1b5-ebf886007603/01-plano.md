# Plano: Tela melhor de decisão

Branch `cp/tela-melhor-de-decisao-7305faf4`, já em `origin/main` (12f34fa): o fast-forward
não tinha nada a trazer e não há commits alheios.

## Entendimento

Hoje uma tarefa em `awaiting_decision` mostra um parágrafo (`decision_reason`). Às vezes há
também botões com as frases de `opcoes` (`Tasks.options/1`), e o agente da tentativa seguinte
recebe só o texto `"Decisão: <frase>"` junto das instruções (`Tasks.decide/5`).

Depois desta tarefa:

1. **Bloqueio.** Quando o agente bloqueia, ele responde com `perguntas` estruturadas: de 1 a 4
   perguntas, cada uma com de 2 a 4 opções descritas, uma delas recomendada e com `preview`
   opcional. A pessoa responde num questionário na tela, e o "Outro" com texto livre existe
   sempre.
2. **Falha.** Quando a tarefa pausa por falha (tentativas esgotadas, gates reprovados, erro do
   CLI), a plataforma pede sozinha uma análise ao agente, uma proposta de um tipo novo. A
   análise devolve um diagnóstico e um questionário no mesmo formato. Enquanto ela roda, a tela
   mostra "o agente está analisando a falha…". A decisão manual de hoje continua disponível o
   tempo todo.
3. **Respostas.** As respostas ficam gravadas no `Decision` como dado estruturado. A próxima
   tentativa as recebe numa seção própria do prompt ("Respostas da pessoa às suas perguntas"),
   e elas aparecem no histórico e no comentário da issue.
4. **Tela.** O questionário é um componente único, usado no painel da tarefa
   (`TaskLive.Show`) e na página Decisões (`DecisionsLive`), e atualiza ao vivo.

### Verificação prévia: `AskUserQuestion` no modo `-p`

Rodei `claude -p` 2.1.318 com as mesmas flags do runner
(`PipeMaestroRunner.Claude`: `--dangerously-skip-permissions --no-session-persistence
--output-format stream-json`) e pedi ao agente que usasse `AskUserQuestion`.

- **Resultado:** a ferramenta não existe nesse modo. O `ToolSearch` respondeu
  `"No matching deferred tools found"`, o agente seguiu e a execução terminou normalmente.
- **Nada trava nem é negado.** O agente só não tem como perguntar, então tende a escrever a
  pergunta no texto final, que se perde.
- **Ação:** o cabeçalho fixo do prompt das etapas (`Prompt.header/4`) passa a dizer que não
  existe ferramenta de perguntar e que toda pergunta vai no campo `perguntas` da saída
  estruturada, com `status: "bloqueado"`. O runner não muda.

### Critérios de aceite (verificáveis)

| # | Critério | Prova |
|---|---|---|
| A1 | `perguntas` é validado: 1 a 4 perguntas, `titulo` com no máximo 12 caracteres, `pergunta` terminando em "?", 2 a 4 opções, `multipla` e "Outro" implícito | `QuestionnaireTest` |
| A2 | O `opcoes` antigo vira uma pergunta única gerada pela plataforma | `QuestionnaireTest`, `TasksTest` |
| A3 | A pausa por falha dispara a análise automática sem clique | `TasksTest` (análise) |
| A4 | Se a análise falha, é cancelada ou chega tarde, a decisão manual segue disponível e nada fica preso | `TasksTest`, `TaskLive.ShowTest` |
| A5 | As respostas ficam no `Decision` e chegam ao prompt da próxima tentativa | `TasksTest`, `PromptTest` |
| A6 | O comentário da issue traz as perguntas e as respostas | `TasksTest` (issue) |
| A7 | O questionário renderiza, e o envio fica bloqueado até todas as perguntas estarem respondidas | `TaskLive.ShowTest` |
| A8 | A múltipla escolha e o "Outro" funcionam | `TaskLive.ShowTest`, `DecisionsLiveTest` |
| A9 | "Responder e continuar" repete a etapa | `TaskLive.ShowTest`, e2e |
| A10 | A atualização ao vivo aparece em outra sessão | `TaskLive.ShowTest` com duas LiveViews |
| A11 | e2e: o fluxo de bloqueio com perguntas e o fluxo de falha com análise | `e2e/tests/decision-questionnaire.spec.ts` |
| A12 | Capturas de `make e2e.shots`, claro e escuro, larga e estreita, conferidas | `make e2e.shots` |
| A13 | ADR 0028, a spec da máquina de estados e o guia de UI atualizados | revisão |
| A14 | `make ci` e `make e2e` verdes | gates |

## O dado: o questionário

O módulo novo é `PipeMaestro.Tasks.Questionnaire`: puro, sem Repo, com `@spec` em tudo.

### Formato (chaves em string, gravado em jsonb)

```elixir
%{
  "origem" => "agente" | "opcoes" | "analise",
  "diagnostico" => "Markdown" | nil,        # só na análise
  "perguntas" => [
    %{"titulo" => "Navegador", "pergunta" => "Em qual navegador reproduz?",
      "multipla" => false,
      "opcoes" => [%{"rotulo" => "Safari 17", "descricao" => "…",
                     "recomendada" => true, "preview" => "```…```" | nil}, …]}
  ]
}
```

As respostas são uma lista alinhada às perguntas:
`[%{"escolhas" => ["Safari 17"], "outro" => "texto" | nil}]`.

### Funções

- **`normalize(output)`** lê a saída do agente de forma defensiva e devolve
  `{:ok, perguntas} | :error`.
  - **Rejeita** o que fere os limites: menos de 1 ou mais de 4 perguntas, menos de 2 ou mais de
    4 opções, pergunta sem "?".
  - **Trunca** `titulo` em 12 caracteres e o `rotulo` em 5 palavras, em vez de jogar a pergunta
    fora.
  - **Ordena** as opções com a recomendada primeiro.
- **`from_options(opcoes)`** é a convivência com o formato antigo: gera uma pergunta única
  (`titulo` "Caminho", `pergunta` "Como a etapa deve seguir?", `multipla` false), uma opção por
  frase com `descricao` vazia. Aceita também uma única frase, porque o "Outro" completa a escolha.
- **`for_run(structured_output)`** usa `perguntas` válidas; senão, `opcoes` não vazias via
  `from_options/1`; senão, `nil`.
- **`validate_answers(perguntas, respostas)`** exige uma resposta por pergunta:
  - pelo menos uma escolha ou um "Outro" não vazio;
  - uma única escolha quando `multipla` é false;
  - escolhas entre os rótulos oferecidos.

  Devolve `{:ok, respostas} | {:error, motivo}`.
- **`to_markdown(perguntas, respostas)`** gera o texto legível para o prompt, o comentário da
  issue e o histórico (pergunta → resposta).

### Schema base (`PipeMaestro.Pipelines.Prompt`, `@base_schema`)

- **`perguntas` entra como propriedade**, com `minItems: 1`, `maxItems: 4`,
  `titulo.maxLength: 12` e as opções com `minItems: 2`, `maxItems: 4`. Cada opção exige
  `rotulo`, `descricao` e `recomendada`, e `preview` é opcional.
- **Sem `if/then`.** "Exigido quando `status` é `bloqueado`" fica na descrição do campo e é
  imposto pela plataforma, não pelo JSON Schema. Não sabemos se o `--json-schema` do CLI aceita
  essas construções, e um schema recusado derrubaria todas as etapas. O que a plataforma faz com
  um bloqueio sem perguntas válidas está em "Mudanças no domínio".
- **`opcoes` continua no schema**, com a descrição "obsoleto: use perguntas". Pipelines cujo
  prompt ainda fala em `opcoes` (`Pipelines.Templates`, linha 46) seguem válidos, e os templates
  passam a pedir `perguntas`.
- **O cabeçalho fixo (`Prompt.header/4`)** ensina a perguntar:
  - só o que muda a solução;
  - uma decisão por pergunta;
  - a recomendada primeiro;
  - nada que o agente descubra sozinho no código;
  - não existe `AskUserQuestion`, toda pergunta vai em `perguntas`.

## Mudanças por app

### `pipe_maestro` (domínio)

#### Migrações (`apps/pipe_maestro/priv/repo/migrations/`)

1. **`tasks`:**
   - `decision_questionnaire :map`, o questionário da pausa atual (nulo sem pausa ou sem
     questionário);
   - `decision_analysis_job_id :binary_id`, referência a `jobs` com `on_delete: :nilify_all`
     (a análise automática da pausa atual).
2. **`decisions`:** `questions :map` (a lista de perguntas, envolvida num mapa
   `%{"perguntas" => …}` para o jsonb) e `answers :map` (`%{"respostas" => …}`). Ambos são
   nulos nas decisões antigas, e as colunas `options` e `choice` ficam como estão.
3. **`stage_runs`:** `answers :map`, as perguntas e respostas que a tentativa recebeu, para o
   prompt e para a tela da tentativa.

As três colunas são novas e anuláveis: não há backfill, e os dados existentes seguem lidos pelo
caminho antigo.

#### Schemas

- **`Tasks.Task`, `Tasks.Decision` e `Tasks.StageRun`** ganham os campos acima, com os
  `@type` atualizados.
- **O moduledoc de `Decision`** descreve as perguntas e respostas estruturadas e diz que
  `options` e `choice` são o formato antigo.

#### `PipeMaestro.Tasks`

**Ao pausar** (`await/2` vira `await/3`, com o que motivou a pausa):

- **Bloqueio com perguntas.** No `{:blocked, _}` de `go_on/3` e no `close_step/2` com etapas
  bloqueadas, `Questionnaire.for_run/1` dá o questionário de cada etapa bloqueada.
- **Grupo.** Num grupo, as perguntas das etapas bloqueadas são concatenadas. Cada `titulo`
  ganha o nome da etapa só na tela, nunca no dado, e o total fica em até 4 por etapa.
- **Sem perguntas.** Um bloqueio sem perguntas válidas nem `opcoes` é tratado como uma falha:
  a plataforma dispara a análise.
- **Falha.** `{:exhausted, _}`, ou um grupo com etapas `failed` e nenhuma pergunta, grava a pausa
  e depois chama `request_analysis/1`.
- **Sem análise.** A pausa por regra, por orçamento ou a pedido (`pause_requested`) não ganha
  questionário nem análise: está fora do escopo ("bloquear ou falhar").

**`request_analysis(task)`:**

- **Pedido.** Pede uma proposta do tipo novo `"analysis"` (ver abaixo) via
  `Proposals.request/5`, em nome de `task.created_by_user`.
- **Sem worktree descartável.** Se o runner não anuncia `"scratch"`, pede sem `directory`: o
  agente lê só o contexto, sem o código.
- **Sem criador.** Se a tarefa não tem `created_by_user`, ou o pedido falha, não há análise. A
  falha vai para o `Logger`, sem silêncio, e a tela mostra a decisão manual.
- **Associação.** Grava `decision_analysis_job_id` e notifica.

**`analysis_finished(job)`** é chamada por `Jobs.finished/1`. Hoje essa função só trata jobs com
`stage_run_id`, e ganha uma cláusula para propostas `"analysis"`.

- **Pausa vencida.** Só age se `AnalysisKind.current?/2` (reaproveita a lógica de
  `DecisionKind.current?/2`: mesma etapa, nenhuma decisão desde então) e se o job é o
  `decision_analysis_job_id` da tarefa.
- **Sucesso.** Com `Proposals.result/1` ok, grava `decision_questionnaire` com
  `origem: "analise"` e o diagnóstico.
- **Falha.** Em qualquer outro caso (job `failed`, `canceled`, saída inválida), não grava nada.
  A tela vê o job terminado e mostra "a análise não ficou pronta" ao lado da decisão manual.
- **Aviso.** Notifica `{:task, id}`, `{:workspace, id}` e `{:decisions, id}` (`notify/1`).

**`answer(task, respostas, instructions, opts)`** é a ação nova "Responder e continuar":

- valida com `Questionnaire.validate_answers/2` e devolve `{:error, :invalid_answers, motivo}`
  se falhar;
- grava o `Decision` com `action: :retry`, `questions` e `answers`;
- repete a etapa (ou as etapas pendentes do grupo) como `retry_stage/3`;
- leva as respostas para o novo `StageRun.answers`.

`advance/3` passa a aceitar respostas opcionais (`opts[:answers]`), validadas parcialmente,
porque "Avançar mesmo assim" não exige tudo respondido. Ela as entrega à etapa seguinte.

**`decide/5`:**

- **Concorrência.** Passa a ler a tarefa com `lock: "FOR UPDATE"` numa transação, para que duas
  pessoas respondendo ao mesmo tempo não gerem duas decisões nem dois jobs. Hoje existe essa
  janela.
- **Análise em curso.** Ao decidir, se `decision_analysis_job_id` aponta para um job ativo, ele
  é cancelado com `Jobs.request_cancel/1`. A análise vale só para aquela pausa.

**Limpeza.** `start_stage/4` e `finish/2` limpam `decision_questionnaire` e
`decision_analysis_job_id`, como já fazem com `decision_reason`.

**`start_stage/4` → `start_stage/5`** recebe as respostas (`answers`), grava-as no `StageRun` e
as passa a `Prompt.build/2`. `start_step` e `next_or_finish` repassam as respostas.

**Comentário da issue.** `issue_comment/4` ganha as perguntas e respostas em Markdown
(`Questionnaire.to_markdown/2`) quando existem; senão continua com o formato atual.

**`options/1`** fica, para compatibilidade. Surge a função nova
`questionnaire(task) :: %{questionnaire: map | nil, analysis: :none | :running | :failed}`,
que as telas usam.

**`record_decision`** grava `questions` e `answers`. A auditoria `"task.decided"` fica igual e
acrescenta `"answered" => true` ao metadata.

#### `PipeMaestro.Pipelines.Prompt`

- `@base_schema` e o cabeçalho fixo, como descrito em "O dado".
- O `context` ganha `optional(:answers)`, e `build/2` acrescenta, depois do feedback, a seção
  `"Respostas da pessoa às suas perguntas (têm prioridade sobre suposições):\n" <>
  Questionnaire.to_markdown(...)`.

#### `PipeMaestro.Proposals.AnalysisKind` (novo)

`AnalysisKind` implementa `Proposals.Kind`. Nome `"analysis"`, rótulo "Análise de falha",
ícone `hero-magnifying-glass`.

- **Por que um tipo novo.** O `DecisionKind` devolve uma ação recomendada (`acao` e
  `instrucoes`, ambos obrigatórios) e alimenta o "Sugerir com IA" manual, que continua como
  está. A análise devolve outra coisa: um diagnóstico e perguntas.
- **Contexto.** Reaproveita `DecisionKind.context/1`, que já cobre o erro, a saída dos gates
  (`Engine.feedback/3`), o diff, os artefatos e o resumo das últimas tentativas.
- **Pedido.** `changeset/2` igual ao do `DecisionKind`, mais `stage` e `decisions` para o
  `current?/2`. Fica registrado em `Proposals.kinds/0` e `@kinds`.
- **Schema da resposta.** `$comment: "pipemaestro-kind:analysis"`, com `diagnostico`
  (Markdown) e `perguntas` (o mesmo schema do `@base_schema`, que fica exposto como
  `Prompt.questions_schema/0`).
- **Prompt de sistema.** Ensina a perguntar bem: só o que muda a solução, opções que de fato
  corrigem a falha, a recomendada primeiro.
- **Teto.** `max_budget_usd: 1` e `timeout_ms: 10 min`, menores que os do `DecisionKind`,
  porque roda sem ninguém pedir.
- **Sem segredos.** Propostas já não recebem os segredos do workspace
  (`RunnerChannel`, linha 159), e nada muda aí.
- **Resultado.** `result/2` passa a saída por `Questionnaire.normalize/1` e devolve
  `{:error, …}` sem perguntas válidas.
- **Aparece na página Propostas.** Os jobs de análise entram em `Proposals.list/3`, filtráveis
  por tipo. `ProposalLive.Show` ganha uma cláusula que mostra o diagnóstico e o questionário em
  modo leitura, com link para a tarefa. A página não aplica nada: a resposta acontece na tarefa.

#### `PipeMaestro.Jobs`

`finished/1` ganha uma cláusula: o job de proposta `"analysis"` chama
`Tasks.analysis_finished/1`. Isso vale para todos os caminhos de fim de job:

- `finish_job`;
- o cancelamento;
- o fim de jobs órfãos.

A conferir: se `Maintenance` encerra jobs sem passar por `finished/1`, ele também passa a
chamar essa função.

### `pipe_maestro_web`

- **`PipeMaestroWeb.QuestionnaireComponents`** (novo; ver "Telas"):
  - `questionnaire/1` (função) mostra o questionário em modo leitura, para o histórico e para a
    página de propostas;
  - o LiveComponent `PipeMaestroWeb.QuestionnaireLive` (stateful) guarda as respostas em
    andamento, o progresso e o passo de revisão, e envia ao pai
    `{:questionnaire, task_id, :answer | :advance, respostas, instrucoes}`.
- **`TaskLive.Show`**:
  - o painel de decisão usa o componente;
  - "Sugerir com IA" e a decisão manual (instruções + "Refazer etapa" / "Seguir") ficam num
    bloco recolhível "Decidir sem responder", com os `data-testid` atuais (`decision-retry`,
    `decision-advance`, `decision-instructions`, `decision-suggest`);
  - o histórico "Decisões tomadas" mostra pergunta → resposta quando há `answers`, e o formato
    antigo quando não há;
  - a tentativa mostra as respostas que recebeu.
- **`DecisionsLive`**: cada card usa o mesmo componente, com `id` por tarefa.
  `load/1` troca `options` por `Tasks.questionnaire/1` por tarefa.
- **Ao vivo.** As duas telas já assinam `{:task, id}` e `{:workspace, id}`. Com a
  `analysis_finished/1` e a decisão de outra pessoa notificando, a tela reage:
  - o questionário aparece quando a análise termina;
  - o painel some, com um flash "Outra pessoa respondeu", quando a tarefa sai de
    `awaiting_decision`.

  O LiveComponent preserva as respostas em andamento enquanto o questionário for o mesmo.
- **`PipeMaestroWeb.Markdown`** renderiza o `preview` e o diagnóstico, com o highlight que já
  usa nos artefatos.
- **Channels: nada muda.**

### `pipe_maestro_protocol`: não muda

O schema de saída viaja como hoje, dentro do `output_schema` do `Job`, um mapa livre. Nenhum
campo, mensagem ou versão muda.

### `pipe_maestro_runner`

- **Código: não muda.** A verificação do `AskUserQuestion` está em "Entendimento".
- **Suporte de testes muda: `apps/pipe_maestro_runner/test/support/fake_claude`.**
  - **Marcador `[perguntas]`:** responde `status: "bloqueado"` com duas perguntas (uma simples
    e uma `multipla`, uma delas com `preview`). Sai do bloqueio quando o prompt traz
    `[desbloqueio]`, que o e2e escreve no "Outro".
  - **Tipo `analysis`:** um diagnóstico e uma pergunta cuja opção recomendada tem o rótulo
    `Tentar sem falha`.
  - **`[falha]`** passa a ser ignorado quando o prompt contém `Tentar sem falha`. A falha fica
    recuperável pela resposta, e os testes que usam `[falha]` sem resposta não mudam.

## Fronteiras

- **Domínio sem web.** `Questionnaire`, `AnalysisKind` e as mudanças em `Tasks`, `Jobs` e
  `Prompt` ficam em `apps/pipe_maestro`, sem nenhum import web. O questionário trafega como
  mapas.
- **Web.** Depende só do domínio, como hoje.
- **Runner.** Só o script de teste muda, e ele continua dependendo apenas de `protocol`.
- **Protocol.** Não muda.

## Protocolo

- **Não toca `apps/pipe_maestro_protocol`** nem o formato das mensagens dos Channels.
- **Spec.** `docs/specs/protocolo-runner.md` não muda e a versão não sobe.
- **Runner antigo: compatível.** Ele recebe um `output_schema` maior (o campo opcional
  `perguntas`) e o repassa ao `--json-schema` como faz com qualquer schema de etapa. A análise é
  uma proposta comum:
  - com o capability `"scratch"`, roda num worktree descartável;
  - sem ele, a plataforma pede a análise sem `directory`, e o agente não lê o código.

## Telas

As telas que mudam são `TaskLive.Show` (painel de decisão, histórico, tentativa),
`DecisionsLive` e `ProposalLive.Show` (leitura da análise).

### Layout do questionário (Petal antes de Tailwind)

- **Cabeçalho.**
  - O diagnóstico vai num `<.alert color="warning" with_icon>`, ou "info" na análise, com o
    Markdown renderizado.
  - Ao lado, o progresso: `<.badge>` "2 de 3 respondidas" e uma barra `<.progress>`. Antes de
    usar a barra, conferir os attrs reais em `deps/petal_components` e em
    `docs/guias/ui-petal.md`.
- **Cada pergunta** é um `<.card variant="outline">`:
  - o `titulo` como `<.badge>`;
  - a pergunta em `<.h4>` ou texto em destaque;
  - as opções como cartões selecionáveis: `<label>` com `<input type="radio|checkbox">`
    escondido e estado visual por `has-[:checked]:`.
    - Se o Petal tiver um `radio_card` ou `checkbox_card`, usá-lo; conferir antes de escrever.
    - Cada cartão mostra o `rotulo`, a `descricao` em texto secundário e o selo
      `<.badge color="success">` "recomendada".
    - O `preview` abre num `<details>` "Ver exemplo" e é renderizado pelo `Markdown` com
      highlight.
  - "Outro" é sempre a última opção, com campo de texto que se habilita ao ser escolhido.
- **Rodapé.**
  - O botão "Responder e continuar" (`hero-paper-airplane`) fica desabilitado enquanto
    faltarem respostas. Ao clicar, mostra o passo de revisão (lista pergunta → resposta, com
    "Voltar" e "Confirmar").
  - "Avançar mesmo assim" (`hero-forward`, outline) fica sempre disponível.
  - "Cancelar a tarefa" (`hero-x-mark`, `color="danger"`) só aparece com
    `can?(scope, :cancel_task, task)`.
- **Estados.**
  - "O agente está analisando a falha…" com spinner (`<.spinner>`) enquanto o job de análise
    está ativo.
  - "A análise não ficou pronta; decida manualmente abaixo" quando o job termina sem
    questionário.
- **Tela estreita.** Opções em uma coluna (`grid sm:grid-cols-2`) e botões em `flex-wrap`, com
  `w-full` no mobile.

### `data-testid`

Na página Decisões, os ids do componente ganham o sufixo `-<task_id>`, pelo `attr :key`.

| id | Elemento |
|---|---|
| `questionnaire` | o contêiner |
| `questionnaire-diagnosis` | o diagnóstico |
| `questionnaire-progress` | o progresso |
| `questionnaire-analyzing` | o estado "analisando" |
| `questionnaire-analysis-failed` | o estado "análise não ficou pronta" |
| `question-<n>` | o card da pergunta |
| `question-<n>-option-<m>` | o cartão da opção |
| `question-<n>-preview-<m>` | o preview da opção |
| `question-<n>-other` | a opção "Outro" |
| `question-<n>-other-text` | o campo de texto do "Outro" |
| `questionnaire-submit` | "Responder e continuar" |
| `questionnaire-review` | o passo de revisão |
| `questionnaire-confirm` | "Confirmar" |
| `questionnaire-back` | "Voltar" |
| `questionnaire-advance` | "Avançar mesmo assim" |
| `questionnaire-cancel` | "Cancelar a tarefa" |
| `decision-manual` | o bloco recolhível da decisão manual |
| `task-decision-answers-<n>` | as respostas no histórico |

### Playwright

- **Spec nova `e2e/tests/decision-questionnaire.spec.ts`**, com `@flow` no cabeçalho:
  - **A:** uma etapa `[perguntas]` bloqueia. A pessoa escolhe a opção recomendada, marca duas
    na múltipla, escreve `[desbloqueio]` no "Outro", revisa, confirma, e a tarefa conclui.
  - **B:** uma etapa `[falha]` com `max_attempts` 1 pausa. Aparece "analisando…", depois o
    diagnóstico e o questionário. A pessoa escolhe "Tentar sem falha", confirma, e a tarefa
    conclui.
  - **C:** o mesmo questionário na página Decisões.
- **Page object.** `e2e/pages/TasksPage.ts` ganha `answerQuestion(n, m)`, `fillOther(n, text)`,
  `submitAnswers()` e `confirmAnswers()`.
- **Spec existente.** O fluxo C de `task-pipeline.spec.ts` segue pela decisão manual. Como o
  bloqueio sem perguntas agora dispara a análise, o fluxo precisa abrir `decision-manual` antes
  de `retryWith`. Ajustar o page object.
- **Capturas.** `make e2e.shots` captura o questionário (bloqueio, análise em curso, revisão,
  histórico), claro e escuro, em viewport larga e estreita (por exemplo, 390 px), se a config de
  shots ainda não tiver a estreita. As capturas são conferidas uma a uma.

## Testes

### `pipe_maestro`

- **`test/pipe_maestro/tasks/questionnaire_test.exs`** (A1, A2): `normalize/1` com cada
  limite, as truncagens, a ordenação, `from_options/1`, `for_run/1`, `validate_answers/2`
  (única × múltipla, "Outro" vazio × preenchido, rótulo inexistente, número de respostas) e
  `to_markdown/2`.
- **`test/pipe_maestro/pipelines/prompt_test.exs`** (A5): o schema base tem `perguntas`, o
  cabeçalho orienta sobre `perguntas` e `AskUserQuestion`, e a seção de respostas aparece no
  `build/2` só quando há respostas.
- **`test/pipe_maestro/tasks_test.exs`:**
  - um bloqueio com `perguntas` grava `decision_questionnaire` com origem `agente`;
  - um bloqueio só com `opcoes` gera a pergunta única (A2);
  - `{:exhausted, _}` cria o job de análise e grava `decision_analysis_job_id`;
  - um runner sem `scratch` recebe a análise sem `directory` (A3);
  - uma análise que falha ou é cancelada deixa `retry_stage`/`advance` funcionando;
  - uma análise que termina depois de uma decisão é ignorada;
  - decidir cancela a análise ativa (A4);
  - `answer/4` grava `questions` e `answers` no `Decision`, cria o `StageRun` com `answers`, e o
    prompt do job contém a seção de respostas;
  - respostas inválidas são recusadas (A5);
  - `issue_comment` com perguntas e respostas (A6);
  - um grupo com duas etapas bloqueadas junta as perguntas;
  - uma decisão concorrente devolve `:not_awaiting` na segunda.
- **`test/pipe_maestro/proposals/analysis_kind_test.exs`:** contexto, schema, `result/2`
  válido e inválido, e `current?/2`.
- **`test/pipe_maestro/jobs_test.exs`:** o fim de um job `"analysis"` chama
  `analysis_finished/1`.

### `pipe_maestro_web`

- **`test/pipe_maestro_web/live/task_live/show_test.exs`:**
  - o questionário renderiza, e `questionnaire-submit` fica desabilitado até tudo respondido
    (A7);
  - a múltipla escolha e o "Outro" funcionam (A8);
  - a confirmação repete a etapa: um novo `StageRun` com respostas (A9);
  - duas LiveViews na mesma tarefa: a resposta numa remove o painel da outra, e o fim da análise
    faz o questionário aparecer nas duas (A10);
  - os estados "analisando" e "falhou";
  - o histórico mostra pergunta → resposta.
- **`test/pipe_maestro_web/live/decisions_live_test.exs`:** o questionário por tarefa, e
  responder a partir da lista.
- **`test/pipe_maestro_web/components/questionnaire_components_test.exs`:** o modo leitura.

### `pipe_maestro_runner`

Nenhum teste novo de código. Se `job_runner_test.exs` cobre os marcadores do `fake_claude`,
acrescentar o caso `[perguntas]`.

### Cobertura

O questionário é lógica pura e bem testável. O LiveComponent é coberto pelos testes de
LiveView. Nenhuma exclusão nova.

## Documentação

- **ADR `docs/adr/0028-questionario-de-decisao.md`:**
  - o dado `perguntas` (formato e limites, imposto pela plataforma e não por `if/then` no
    schema);
  - a convivência com `opcoes` (pergunta única gerada);
  - o `AskUserQuestion` ausente no `-p` (verificado) e a orientação no cabeçalho;
  - a análise automática na falha (tipo `analysis`, teto, sem segredos, válida só para a pausa,
    cancelada ao decidir, sem bloquear a decisão manual);
  - as respostas no `StageRun` e no prompt.

  Deve referenciar as ADRs 0011, 0021 e 0022.
- **`docs/specs/maquina-de-estados-tarefa.md`:**
  - a tabela do gate ganha a coluna "questionário" (agente / análise / nenhum);
  - a seção "Decisões" ganha "Responder e continuar" e a análise automática (estado
    `decision_analysis_job_id`, cancelamento ao decidir);
  - a nota de `awaiting_decision` menciona `decision_questionnaire`.
- **`docs/guias/ui-petal.md`:** o padrão de cartões selecionáveis (radio/checkbox) e onde vive
  o `QuestionnaireComponents`.
- **ADR 0022 (propostas como mecanismo geral):** atualizar a lista de tipos, ou apontar para a
  0028.
- **`e2e/README.md`:** os ids novos, se o README lista convenções por tela.

## Riscos

- **Migrações.** Só colunas novas e anuláveis, sem backfill. Decisões antigas sem
  `questions`/`answers` usam o caminho antigo na tela e no comentário.
- **Jobs em voo durante o deploy.** Um job de etapa já despachado com o schema antigo volta sem
  `perguntas`:
  - se tiver `opcoes`, vira a pergunta única;
  - se não tiver, dispara a análise.
- **Custo da análise automática.** Cada pausa por falha gasta até US$ 1. O valor fica numa
  constante do `AnalysisKind`.
  - Se o workspace preferir desligar, um ajuste por pipeline fica para depois. **Não está no
    escopo.**
  - O bloqueio sem perguntas também paga a análise. A alternativa seria mostrar só a decisão
    manual; escolhi a análise para cumprir "sempre que bloquear".
- **Runner offline ou ocupado.** A análise fica `queued` e a tela mostra "analisando…" enquanto
  isso. A decisão manual está sempre visível (recolhida), então nada fica preso. Se a pessoa
  decidir, a análise é cancelada.
- **Concorrência.** O `decide/5` com `FOR UPDATE` evita a dupla decisão. Ainda pode acontecer
  de uma análise terminar depois de uma decisão; `current?/2` e a checagem do
  `decision_analysis_job_id` resolvem.
- **CLI e schema.**
  - Se o `--json-schema` não aceitar `maxLength` ou `minItems`, a etapa falha. Mitigação:
    testar o schema novo com o `claude` real numa execução local antes do e2e.
  - Se o agente ferir os limites, `normalize/1` trunca ou recusa.
- **Dialyzer.** Os mapas do questionário ficam em `@type` explícitos
  (`Questionnaire.question()`, `answer()`), e `await/3` e `start_stage/5` mudam de aridade com
  `@spec` privados coerentes.
- **e2e existente.** O fluxo C de `task-pipeline.spec.ts` muda porque o bloqueio sem perguntas
  agora dispara a análise. Ele pode ficar lento se o runner do e2e estiver ocupado com ela; o
  page object espera `decision-manual`.
- **Escopo do `TaskKind`.** O componente aceita o formato das perguntas para ser reaproveitado.
  Migrar as `perguntas` do `TaskKind` (hoje uma lista de frases) para o formato estruturado
  **fica fora**: o critério diz "reaproveitável", não "migrado".

## Ordem de execução sugerida

1. `Questionnaire` e os testes.
2. O schema base e o cabeçalho do `Prompt`, com os testes.
3. As migrações e os schemas.
4. `Tasks`: pausa com questionário, `answer`, respostas no prompt e no comentário da issue, lock.
5. `AnalysisKind`, a cláusula de `Jobs.finished/1` e `request_analysis`/`analysis_finished`.
6. `fake_claude`.
7. O componente e as telas, com os testes de LiveView.
8. O e2e e as capturas.
9. Os docs.
10. `make ci` e `make e2e`.
