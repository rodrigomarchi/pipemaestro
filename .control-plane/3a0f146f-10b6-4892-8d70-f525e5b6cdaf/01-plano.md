# 01 — Plano: questionário estruturado (ADR 0029) nas perguntas da proposta de tarefa

Base: `origin/main` em `225fdfd`. A branch não tinha commits próprios, e o fast-forward não trouxe nada.

## Entendimento

Hoje, quando a IA escreve uma tarefa (proposta `task`) e conclui que ela não está pronta,
`perguntas` é uma lista de frases. Essas frases aparecem como lista simples na tela da
proposta, no motivo do auto-approve `skipped` e no comentário de triagem da issue. Para
responder, a pessoa usa o nó "ajustes" com texto livre.

Depois desta mudança:

- o agente devolve até 4 perguntas no formato do ADR 0029, cada uma com título, pergunta,
  múltipla escolha ou não, e 2 a 4 opções. A opção recomendada vem marcada e pode trazer
  preview;
- na tela da proposta, as perguntas viram o questionário respondível que já existe para as
  decisões de tarefa: opções em cards, "Outro", progresso e revisão antes de enviar;
- ao enviar, nasce uma nova rodada da proposta. Ela leva as respostas em Markdown no
  `feedback`, e a página navega até ela;
- o motivo do auto-approve e o comentário de triagem na issue listam as perguntas
  numeradas, com as opções e a recomendada indicada;
- propostas antigas, com frases, continuam aparecendo como lista simples.

Os critérios de aceite são os da tarefa. A seção "Testes" diz qual teste prova cada um.

## Mudanças por app

### `apps/pipe_maestro` (domínio)

1. **`Proposals.TaskKind`** (`lib/pipe_maestro/proposals/task_kind.ex`)
   - `schema/0`: `"perguntas" => Prompt.questions_schema()`, reaproveitado, sem cópia.
     Esse schema tem uma `description` que fala em "quando bloqueado", pensada para as
     etapas. O teste de aceite pede igualdade com `Prompt.questions_schema()`, então o
     schema fica como está. A regra "só quando `pronta` é `false`" vai no `system_prompt`.
     `perguntas` continua fora do `required`.
   - `system_prompt/0`: troca a frase de `pronta` por um bloco "## Perguntas". O bloco diz:
     - só pergunte quando `pronta` for `false`; com `pronta: true`, deixe `perguntas` vazia;
     - de 1 a 4 perguntas, cada uma uma decisão que muda a tarefa e que o código não
       responde;
     - de 2 a 4 opções, a recomendada marcada (`recomendada: true`, uma só, a primeira),
       com `descricao` dizendo o que a escolha implica e `preview` opcional;
     - "Outro" é sempre oferecido pela plataforma e não entra nas opções;
     - não existe `AskUserQuestion`.
   - `result/2`: as perguntas são lidas num ponto só, uma função privada `questions/1`:
     - `Questionnaire.normalize(output["perguntas"])` dá `{:ok, qs}` → `questions: qs`,
       `legacy_questions: []`;
     - `:error` → `questions: []`, `legacy_questions:` as strings da lista. Isso cobre o
       formato antigo; lixo dá listas vazias.
   - `changeset/2`: o limite de `feedback` sobe de 4 000 para **8 000**. O texto das
     respostas tem cabeçalho, até 4 perguntas, rótulos curtos e o "Outro" de cada uma. O
     "Outro" não tem limite na tela. O prompt inteiro já é cortado em 30 000 bytes
     (`@prompt_bytes`), com o pedido em até 16 000 e a proposta anterior em até 8 000.
     Para caber sem perder respostas, o "Outro" de cada resposta é cortado em 1 500 bytes
     com `Instructions.cut/2`. A escolha e o começo do texto ficam, e nenhuma pergunta
     some do feedback.
2. **`Tasks.Questionnaire`** (`lib/pipe_maestro/tasks/questionnaire.ex`): a formatação
   legível das perguntas fica num lugar só, para o auto-approve e para a issue:
   - `question_text/1`, com `@spec` e doc: "**Pergunta?** — Opção A (recomendada) · Opção
     B". Hoje existe só como `Feedback.question_text/1`, privada, e passa a vir daqui;
   - `to_text/1`: lista numerada em Markdown, uma pergunta por linha;
   - `Feedback` delega a `Questionnaire.question_text/1`, e o comentário de status das
     decisões de tarefa ganha a marcação da recomendada. A mudança de texto é mínima e
     compatível com os testes, que serão ajustados se compararem a string inteira.
3. **`Proposals`** (`lib/pipe_maestro/proposals.ex`)
   - `auto_result/1`: o motivo é "O agente não considerou a tarefa pronta." seguido de
     `Questionnaire.to_text(questions)` para as perguntas estruturadas, ou das linhas
     `- frase` para `legacy_questions`, como hoje. O padrão casa
     `%{ready: false} = result`.
   - Nova função `answer_questions(user, workspace, job, answers)` (`@spec`, doc). Ela
     concentra a regra, e a LiveView só delega:
     - aceita só uma proposta `task` terminada com sucesso, ainda sem tarefa criada
       (`created_task_id/1` nil) e com `questions != []`. Fora disso devolve
       `{:error, motivo}`;
     - valida com `Questionnaire.validate_answers/2`;
     - monta o feedback (função `answers_feedback/2`): "## Respostas às suas perguntas",
       depois `Questionnaire.to_markdown/2` com o "Outro" cortado, depois "Incorpore estas
       respostas na descrição da tarefa (contexto, comportamento e critérios de aceite).
       Não pergunte de novo o que já foi respondido";
     - chama `request("task", user, workspace, Map.merge(input(job), %{"runner_id" =>
       job.runner_id, "feedback" => feedback}), job)`, o mesmo caminho do `regenerate`;
     - grava `Audit.record(..., "proposal.answered", next, ...)`. O `regenerate` hoje
       grava `proposal.requested` na LiveView; aqui o registro fica no domínio.
4. **`Proposals.Instructions.revision/2`**: o texto de `feedback_section` passa a dizer
   "O que a pessoa pediu para ajustar ou respondeu" e manda refazer a proposta com isso.
   Como o próprio feedback traz o cabeçalho "Respostas às suas perguntas" e a instrução de
   incorporá-las, o agente sabe que são respostas às perguntas dele. Não precisa de campo
   novo no input.
5. **`Integrations.Feedback.triage_comment/2`** (`lib/pipe_maestro/integrations/feedback.ex`)
   - o caso `skipped` continua mostrando o `reason`, que já traz as perguntas numeradas
     com opções pelo item 3. O texto "responda e crie a tarefa na plataforma" passa a
     "responda às perguntas na plataforma, pelo link da proposta";
   - o caso de sucesso sem auto-approve hoje não mostra perguntas. Ele passa a ler
     `Proposals.result(job)` e, quando `ready` é `false` e há perguntas, inclui o mesmo
     bloco (`Questionnaire.to_text/1` ou as frases). O formato vem de um helper só,
     `Proposals.questions_text(result)`, usado também por `auto_result/1`. `Feedback` já
     é chamado por `Proposals`, e uma chamada de volta em tempo de execução não cria ciclo
     de compilação. Isso será conferido com `mix xref graph --format cycles` se preciso.
6. **Migrações**: nenhuma. O dado novo é jsonb em `structured_output` e `context`.

### `apps/pipe_maestro_web`

1. **`QuestionnaireLive`**, generalizado sem duplicação:
   - novos assigns, com padrões que mantêm o comportamento atual das decisões:
     - `values` (mapa de `phx-value-*`), padrão `%{"task_id" => @task_id}`;
     - `actions`, padrão `[:answer, :advance, :cancel]`, com `:cancel` ainda dependendo de
       `can_cancel`;
     - `submit_label`, padrão "Responder e continuar";
   - `task_id` deixa de ser obrigatório. Os botões usam
     `{Enum.map(@values, fn {k, v} -> {"phx-value-#{k}", v} end)}` como atributos
     dinâmicos. `phx-value-*` passa pelo `:global` do `<.button>` do Petal;
   - `TaskLive.DecisionPanel` e `DecisionsLive` não mudam de chamada, porque os padrões
     cobrem o uso atual. O `@moduledoc` documenta os assigns novos.
2. **`ProposalLive.Show`** (`live/proposal_live/show.ex`)
   - em `task_review`, no card "Pronta para rodar?":
     - com `@result.questions != []` e a proposta respondível, renderiza
       `<.live_component module={QuestionnaireLive} id="proposal-questionnaire"
       key="proposta" questionnaire={%{"perguntas" => @result.questions}} actions={[:answer]}
       values={%{}} submit_label="Responder e reescrever a tarefa" />`;
     - com perguntas estruturadas mas sem envio (proposta já convertida, ou a pessoa sem
       permissão), mostra só a leitura com `QuestionnaireComponents.questionnaire/1`;
     - com `legacy_questions != []`, mostra a lista atual em
       `data-testid="proposal-task-questions"`;
   - "respondível" é `not Job.active?(@job) and is_nil(@created_task_id)`. O mount já
     exige `can_review?/2` (`:run_tasks`), e o handler confere de novo;
   - `handle_event("questionnaire", %{"action" => "answer", "answers" => json}, socket)`
     faz `QuestionnaireComponents.decode_answers/1` e
     `Proposals.answer_questions/4`. Se der certo, faz `push_navigate` para a nova
     proposta. Se der erro, mostra o motivo em flash. Os demais `action` ficam sem
     cláusula e não são enviados por esta tela.
3. **Channels**: não mudam.

### `apps/pipe_maestro_protocol`

Não muda.

### `apps/pipe_maestro_runner`

O código não muda. Só o dublê de teste `test/support/fake_claude`, usado pelo e2e, muda:
- `[nao-pronta]` passa a responder `perguntas` estruturadas, uma pergunta "Qual o limite de
  logins simultâneos?" com opções ("100 simultâneos" recomendada, "1 000 simultâneos");
- um prompt que contém "Respostas às suas perguntas" responde `pronta: true`, para provar
  a nova rodada. Essa condição é verificada antes de `[nao-pronta]`, porque o pedido
  continua no prompt;
- os testes do runner que leem esse dublê são conferidos com `cd apps/pipe_maestro_runner
  && mix test`.

## Fronteiras

- O domínio continua sem web: `answer_questions/4` e a formatação ficam em
  `PipeMaestro.Proposals` e `PipeMaestro.Tasks.Questionnaire`, e a LiveView só delega.
- O runner continua dependendo só de `protocol`. Só o script de teste muda.
- Nada entra em `protocol`.

## Protocolo

Não muda. O `output_schema` do job é um mapa livre no `PipeMaestroProtocol.Job`. Um
runner antigo repassa o schema maior ao `--json-schema` como já faz com as etapas
(ADR 0029, Consequências). `docs/specs/protocolo-runner.md` não muda, e a versão não sobe.
Um job despachado antes do deploy volta com frases, que caem em `legacy_questions`.

## Telas

- **Proposta `task`** (`/w/:slug/proposals/:id`, nó "proposta"): o questionário entra no
  card "Pronta para rodar?". Os ids são os do `QuestionnaireLive` com o sufixo
  `key="proposta"`, por exemplo `questionnaire-proposta`, `question-0-option-0-proposta`,
  `question-0-other-text-proposta`, `questionnaire-submit-proposta`,
  `questionnaire-review-proposta` e `questionnaire-confirm-proposta`. As propostas
  antigas mantêm `proposal-task-questions`. Uma tela tem uma proposta só, então um sufixo
  fixo basta e segue o padrão de `e2e/README.md` (sufixo pela chave).
  - **Ponto a verificar:** o card fica numa grade de duas colunas (`xl:grid-cols-2`) ao
    lado da análise. Se as capturas mostrarem o questionário apertado, ele passa para
    largura total acima da análise ("foco no que importa").
- **Componentes Petal:** os já usados pelo `QuestionnaireLive` (`card`, `badge`,
  `progress`, `button`, `input`). Nada novo.
- **Playwright:** `e2e/tests/agent-proposals.spec.ts`, Flow E estendido:
  1. a proposta `[nao-pronta]` mostra o motivo do auto-approve com a pergunta e as opções;
  2. escolher a opção recomendada e enviar;
  3. revisar e confirmar;
  4. a URL muda para a nova proposta, que fica pronta e não mostra o questionário.
  - Capturas `task-proposal-questions` e `task-proposal-answered`, em claro e escuro, com
    `make e2e.shots FILE=tests/agent-proposals.spec.ts`;
  - `decision-questionnaire.spec.ts` roda sem alteração.

## Testes, por critério

| Critério | Teste |
|---|---|
| Schema usa `Prompt.questions_schema/0` | `apps/pipe_maestro/test/pipe_maestro/proposals_test.exs`: `TaskKind.schema()["properties"]["perguntas"] == Prompt.questions_schema()` (como na linha 742 para `analysis`) |
| `result/2`: estruturadas, frases e lixo | `proposals_test.exs`: as estruturadas saem normalizadas (recomendada primeiro, título de 12 caracteres, rótulo de 5 palavras); as strings vão para `legacy_questions` (o teste da linha 251 é ajustado); lixo (`"x"`, `[%{}]`, `nil`) dá listas vazias e não quebra |
| `answer_questions/4` | `proposals_test.exs`: cria um job com o feedback contendo cada pergunta e a escolha ou o "Outro"; recusa respostas incompletas, proposta já convertida, proposta ativa e proposta sem perguntas; o "Outro" longo é cortado e o feedback cabe no limite |
| Motivo do auto-approve nos dois formatos | `proposals_test.exs`, perto das linhas 467–493: o `reason` lista a pergunta, as opções e "(recomendada)"; as frases aparecem como antes |
| Comentário de triagem nos dois formatos | `apps/pipe_maestro/test/pipe_maestro/integrations/ingest_test.exs` (o teste "a triage that is not ready asks its questions on the issue", linha 219) e um caso estruturado; mais um caso sem auto-approve com perguntas |
| `question_text/1` | `apps/pipe_maestro/test/pipe_maestro/tasks/questionnaire_test.exs` (ou onde ficam os testes do `Questionnaire`) |
| Tela: questionário respondível → nova proposta | `apps/pipe_maestro_web/test/pipe_maestro_web/live/proposal_live_test.exs`: escolher opções, usar "Outro", enviar, confirmar; conferir `assert_redirect` e o feedback do novo job; o questionário some numa proposta convertida |
| Tela: proposta antiga | `proposal_live_test.exs`: `proposal-task-questions` mostra as frases |
| Decisões de tarefa intactas | `task_live_test.exs`, `decisions_live_test.exs` e `questionnaire_components_test.exs` sem mudança; o e2e `decision-questionnaire.spec.ts` |
| e2e | Flow E estendido em `agent-proposals.spec.ts` e `make e2e` completo no fim |
| Gate | `make ci` uma vez no fim do bloco |

## Documentação

- **ADR 0029** ganha uma seção "Proposta de tarefa" que diz:
  - a proposta `task` usa o mesmo questionário;
  - responder gera uma nova rodada, com o feedback nas respostas;
  - o `QuestionnaireLive` tem ações e alvo configuráveis;
  - a última consequência ("As `perguntas` do tipo `task` continuam uma lista de
    frases…") é atualizada.
  Um ADR novo não é necessário: é a extensão anunciada pelo próprio ADR.
- **`docs/specs/integracoes.md`** (§5, perto da linha 107): o comentário de triagem sem
  tarefa lista as perguntas numeradas com as opções e a recomendada, e manda responder na
  plataforma pelo link da proposta.
- Nenhum guia muda. O `@moduledoc` do `QuestionnaireLive`, do `TaskKind` e do
  `Proposals` é atualizado.

## Riscos

- **Dados existentes:** propostas antigas têm `perguntas` em frases e um `reason` gravado
  como texto. Os dois continuam legíveis, e não há migração.
- **Schema maior no CLI:** é o mesmo `questions_schema` que as etapas já mandam ao
  `--json-schema`, então o risco é baixo.
- **Concorrência:** duas pessoas respondendo ao mesmo tempo criam duas rodadas. Isso já
  acontece hoje com o `regenerate`, e nada se corrompe, porque cada rodada é um job
  separado. Fica como está.
- **Feedback longo:** o "Outro" é cortado por resposta, e o limite de `feedback` sobe para
  8 000. O prompt continua sob 30 000 bytes, porque `request/5` corta o total.
- **Atributos dinâmicos no `<.button>`:** é preciso confirmar que o Petal repassa
  `phx-value-*` pelo `:global`. Se não repassar, a alternativa é um mapa
  `phx-value-target` codificado.
- **Dialyzer:** os `@spec` novos (`answer_questions/4`, `question_text/1`, `to_text/1`) e
  o mapa de `result` com chaves novas. O tipo de retorno de `Kind.result` é `map()`.
- **Cobertura:** as funções novas têm testes diretos, e o limite de 60% por app não corre
  risco.
- **Testes que comparam texto exato** do comentário de status, que ganha "(recomendada)",
  precisam ser ajustados de propósito.

## Ordem de implementação sugerida

1. Domínio: `Questionnaire.question_text/1` e `to_text/1`, depois `TaskKind`, depois
   `Proposals` (`auto_result`, `questions_text`, `answer_questions`), depois
   `Instructions`, depois `Feedback`, com os testes de cada um.
2. Web: a generalização do `QuestionnaireLive`, depois `ProposalLive.Show`, com os testes
   LiveView.
3. `fake_claude` e o e2e Flow E; capturas em claro e escuro.
4. ADR 0029 e `integracoes.md`.
5. `make ci` e `make e2e`, uma vez cada.
