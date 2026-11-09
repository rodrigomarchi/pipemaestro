# 03 — Implementação

Base: `origin/main` em `225fdfd`, ainda o mesmo. O plano e os testes da etapa 2 estão
implementados. Todos os testes passam, e só um teste foi corrigido (explicado abaixo).

## O que mudou, por app

### `apps/pipe_maestro` (domínio)

- **`Tasks.Questionnaire`**:
  - `question_text/1`: "Pergunta? — Opção (recomendada) · Outra";
  - `to_text/1`: as perguntas numeradas, uma por linha.
  Os dois formatam as perguntas num lugar só, para o motivo do auto-approve e para a issue.
- **`Proposals.TaskKind`**:
  - `perguntas` usa `Prompt.questions_schema()`;
  - o prompt de sistema ganhou uma seção "Perguntas": perguntar só quando `pronta: false`
    e omitir o campo quando a tarefa está pronta, porque o schema tem `minItems: 1`. Cada
    pergunta é uma decisão que muda a tarefa, a recomendada vem marcada e primeiro, e
    "Outro" é da plataforma;
  - `result/2` devolve `questions`, as normalizadas, e `legacy_questions`, as frases
    antigas ou lixo filtrado, num ponto só (`questions/1`);
  - o limite de `feedback` passou para 8 000 (`feedback_length/0`).
- **`Proposals`**:
  - `questions_text/1`: o texto das perguntas de um resultado, nos dois formatos;
  - `auto_result/1` monta o motivo do `skipped` com esse texto;
  - `answer_questions/4` aceita só uma proposta `task` que terminou, tem perguntas e ainda
    não virou tarefa;
  - ela valida com `validate_answers/2`, corta cada "Outro" em 1 500 bytes e põe no feedback
    "### Respostas às suas perguntas", o `to_markdown/2` e a ordem de incorporar as
    respostas na descrição;
  - depois pede a rodada por `request/5`, com o job anterior, e grava a auditoria
    `proposal.answered`.
- **`Proposals.Instructions`**: a seção do feedback agora se chama "O que a pessoa pediu
  para ajustar ou respondeu".
- **`Integrations.Feedback`**:
  - o comentário de status usa `Questionnaire.to_text/1`, e a recomendada aparece marcada
    nas decisões de tarefa também;
  - o comentário de triagem traz o motivo, que já lista as perguntas, e manda responder
    pelo link da proposta;
  - sem auto-approve, ele lista as perguntas pela função privada `open_questions/1`, que
    chama `Proposals.result/1` e `questions_text/1`.

### `apps/pipe_maestro_web`

- **`QuestionnaireLive`**: ganhou os assigns `actions` (padrão `[:answer, :advance,
  :cancel]`) e `submit_label` (padrão "Responder e continuar"), e `task_id` ficou opcional.
  Um `phx-value-task_id` nulo não é renderizado. As decisões de tarefa continuam iguais,
  porque os padrões cobrem o uso atual.
- **`ProposalLive.Show`**:
  - as perguntas estruturadas ficam num card de largura total, "Perguntas do agente"
    (`proposal-task-answers`), acima da grade;
  - nele vai `QuestionnaireLive` com `key="proposta"`, `actions={[:answer]}` e o envio
    "Responder e reescrever a tarefa";
  - uma proposta que já virou tarefa mostra só a leitura (`QuestionnaireComponents`);
  - as frases antigas continuam em `proposal-task-questions`;
  - o handler `"questionnaire"`/`answer` delega a `Proposals.answer_questions/4` e navega
    para a nova proposta, ou mostra o erro em flash.

### `apps/pipe_maestro_runner`

- **`GateCache`**, uma correção fora do escopo, mas nossa pela regra do `AGENTS.md`:
  - a cópia do índice passa a manter o mtime do índice original;
  - com o horário de agora, o git confiava em entradas "racily clean". Um arquivo
    reescrito no mesmo segundo, com o mesmo tamanho, passava por inalterado, e o gate saía
    do cache numa árvore errada;
  - essa era a causa da falha intermitente de `gates_test.exs:54`, anotada na etapa 2;
  - o teste novo "a change of the same size, in the second the index was written, is seen"
    monta o caso de forma determinística. Sem a correção, ele falhou em 3 de 3 execuções,
    e o teste antigo em 2 de 3. Com ela, os 12 testes do arquivo passam.
- O dublê `fake_claude` já tinha sido mudado na etapa 2.

### `apps/pipe_maestro_protocol`

Não mudou.

### Documentação

- **ADR 0029**: ganhou o item "A proposta de tarefa usa o mesmo questionário", e a
  consequência sobre as `perguntas` em frases foi atualizada.
- **`docs/specs/integracoes.md`**: descreve o comentário de triagem com as perguntas
  numeradas, as opções e a recomendada, o pedido para responder pelo link e a nova rodada.

## Correções nos testes da etapa 2

- **`proposals_test.exs`**: o rótulo "5 segundos sob qualquer carga no servidor" cortado
  em 5 palavras dá "5 segundos sob qualquer carga". O teste esperava 4 palavras, por erro
  de contagem; ele foi corrigido, e o contrato de 5 palavras do `normalize/1` ficou igual.
- **`feedback_test.exs`**: o comentário de status das decisões passou a marcar a
  recomendada, com o formato "— Opção (recomendada) · Outra", e a asserção acompanhou.
- **`agent-proposals.spec.ts`**: a contagem final de propostas foi de 6 para 7, porque o
  Flow F cria a rodada das respostas. O Flow F ganhou `[done]`.

## Como verificar

- `make ci.quick`: saiu 0. `mix dialyzer`: 0 erros.
- `make e2e FILE=tests/agent-proposals.spec.ts`: 1 de 1 passa, com o Flow F respondendo
  e a nova rodada virando a tarefa.
- `make e2e FILE=tests/decision-questionnaire.spec.ts`: 3 de 3 passam.
- Na mão: peça uma tarefa com "[nao-pronta]" no texto, usando o `fake_claude`. A proposta
  mostra "Perguntas do agente". Escolha "100 simultâneos", revise e confirme. A página vai
  para a nova proposta, que vira a tarefa sozinha com auto-approve.

## O que fica para a etapa Telas

- As capturas `make e2e.shots` em claro e escuro de `task-proposal-questions` e
  `task-proposal-answered`, auditadas.
- A suíte e2e completa.
