# 04 — Revisão de convenções

Diff revisado contra `origin/main` (`225fdfd`, sem novidades).

## Conferido, sem achados

- **Plano e critérios de aceite:** todos têm teste (ver `02-testes.md`). O schema, `result/2`, o motivo do auto-approve, o comentário de triagem, a tela respondível, a proposta antiga e `answer_questions/4` estão em ExUnit. O fluxo completo está no e2e `agent-proposals.spec.ts` (Flow F). Os testes das decisões de tarefa seguem intactos.
- **`@spec` e `@moduledoc`:** `question_text/1`, `to_text/1`, `questions_text/1` e `answer_questions/4` têm `@spec` e `@doc`. Não há módulo novo.
- **LiveViews finas:** o handler `"questionnaire"` só decodifica as respostas e delega a `Proposals.answer_questions/4`. A regra (estado da proposta, validação, corte, auditoria) fica no domínio.
- **Petal e Tailwind:** o card usa `card`, `section_heading` e `button`, componentes já existentes. Não entrou classe nova de Tailwind.
- **`data-testid`:** `proposal-task-answers` e os ids do questionário com sufixo `-proposta`, no padrão de `e2e/README.md`.
- **Comentários:** descrevem o código, não a mudança.
- **`handle_info`:** nenhum catch-all novo.
- **Fronteiras:** o runner só mudou o `GateCache` (sem Phoenix nem Ecto), e o `protocol` não mudou. O domínio não referencia a web. `Feedback` chama `Proposals` só em tempo de execução, e o compile passa sem ciclo.
- **Cobertura:** nenhuma exclusão nova.
- **Contagens na prosa:** nenhuma nova.
- **Protocolo:** não muda, como o plano disse. O `output_schema` do job é um mapa livre.

## Corrigido

- `TaskKind.feedback_length/0` era API pública sem uso (só o comentário a citava). Foi removida, e o comentário em `Proposals` agora aponta para o módulo.

## Risco conhecido, deixado como está

O texto de cada pergunta não tem limite em `Questionnaire.normalize/1`. O corte de 1.500 bytes por "Outro" cobre o caso normal, mas quatro perguntas muito longas ainda poderiam passar de 8.000 caracteres. O pedido de nova rodada então volta como erro em flash, sem perder nada, e a pessoa pode usar "ajustes". Pôr um limite no texto da pergunta mexeria no ADR 0029 e nas etapas, fora do escopo.

## Verificação

Só `task_kind.ex` e um comentário de `proposals.ex` mudaram nesta etapa. `proposals_test.exs` passa (54 de 54) e `make ci.quick` saiu 0.
