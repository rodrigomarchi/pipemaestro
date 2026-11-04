# Documentação e resumo — Tela melhor de decisão

## Documentos
- **ADR nova:** `docs/adr/0028-questionario-de-decisao.md`, já no índice de `docs/README.md` (adicionado nesta etapa).
- **ADR anterior atualizada:** `docs/adr/0022-propostas-do-agente-como-mecanismo-geral.md` (o tipo `analysis` ao lado do `DecisionKind`).
- **Spec:** `docs/specs/maquina-de-estados-tarefa.md` (pausa com questionário, análise automática, ação "responder").
- **Guia:** `docs/guias/ui-petal.md` (componente do questionário).
- `docs/specs/protocolo-runner.md`, `docs/guias/phoenix.md`, `e2e/README.md` e `docs/plano/` não precisaram de mudança.

## Resumo para quem vai revisar

### O que mudou e por quê
Antes, uma tarefa em `awaiting_decision` mostrava um parágrafo e, às vezes, botões com frases soltas. Agora a pessoa responde um questionário estruturado, e a falha ganha uma análise automática do agente.

- **`apps/pipe_maestro` (domínio):**
  - `Tasks.Questionnaire` (novo, puro) valida e normaliza perguntas e respostas.
  - `Proposals.AnalysisKind` (novo) pede a análise de falha sozinha, sem clique.
  - `Tasks` ganha `answer/4`, `request_analysis/1`, `analysis_finished/1` e `questionnaire/1`.
  - `decide/5` passa a travar a tarefa (`FOR UPDATE`) e a cancelar a análise em curso.
  - O `Prompt` ganha `perguntas` no schema e a seção de respostas da próxima tentativa.
  - Migração em `apps/pipe_maestro/priv/repo/migrations/`: colunas novas e anuláveis, sem backfill.
- **`apps/pipe_maestro_web`:** `QuestionnaireLive` e `QuestionnaireComponents` são usados em `TaskLive.Show` e `DecisionsLive` e atualizam ao vivo. A decisão manual fica em "Decidir sem responder". `ProposalLive.Show` mostra a análise em leitura.
- **`apps/pipe_maestro_protocol`:** não mudou.
- **`apps/pipe_maestro_runner`:** só o `fake_claude` de teste mudou. O código do runner não mudou.

### Protocolo e runners antigos
O protocolo não mudou. `perguntas` entra na saída estruturada que o agente devolve, e não no contrato `Hello`/`Job`/`JobEvent`, então runners antigos funcionam. A saída antiga com `opcoes` continua aceita e vira uma pergunta única. No modo `-p` não existe `AskUserQuestion`, e o cabeçalho do prompt manda perguntar pelo campo `perguntas`.

### Riscos e o que olhar com mais atenção
- **Schema do `--json-schema`:** `perguntas` entra no schema base de todas as etapas. Se o CLI recusar alguma construção, todas as etapas quebram. Evitei `if/then`, e vale conferir numa execução real.
- **Análise automática custa dinheiro:** `max_budget_usd: 1` e 10 min por falha. Sem `created_by_user` ou sem criador válido, não há análise (log no `Logger`) e a decisão manual segue disponível.
- **Concorrência em `decide/5`:** o lock na tarefa e o cancelamento da análise em curso.
- **Análise tardia ou cancelada:** `analysis_finished/1` só age se a pausa ainda é a mesma.
- **Cobertura de borda:** o placeholder do campo "Outro" fica cortado na tela estreita (só visual).

### Como verificar
- `make ci > /tmp/ci.log 2>&1; echo $?` (última execução: exit 0, cobertura total acima do limite).
- `make e2e FILE=tests/decision-questionnaire.spec.ts`, e `make e2e` completo (exit 0).
- `make e2e.shots FILE=tests/decision-questionnaire.spec.ts` para as capturas clara e escura.
- Manual: bloqueie uma etapa que devolva `perguntas`, responda no painel da tarefa e confira "Responder e continuar". Abra a mesma tarefa em outra aba e veja a atualização ao vivo. Force uma falha e veja "o agente está analisando a falha…" e depois o diagnóstico com as perguntas.
