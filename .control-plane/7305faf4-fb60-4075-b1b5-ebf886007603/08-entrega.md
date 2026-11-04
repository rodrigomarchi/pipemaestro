# Entrega — Tela melhor de decisão

## Branch
- **Nome:** `cp/tela-melhor-de-decisao-7305faf4`
- **Base:** `origin/main` (`12f34fa`, "Os alertas do Board"). A branch já contém essa commit; não houve merge nesta etapa, pois `main` não trouxe mudanças novas.
- **Árvore:** limpa antes da entrega. Nenhum push e nenhum PR foram feitos aqui: a plataforma faz o push e marca o PR como pronto.

## Commits da branch (mais antigo primeiro, a partir de `origin/main`)
1. `c97f216` Entendimento e plano: Tela melhor de decisão
2. `afd5db5` Testes que falham: Tela melhor de decisão
3. `af25498` Questionário de decisão no domínio
4. `ae169fe` Questionário de decisão nas telas
5. `0546b30` fake_claude pergunta e analisa; e2e do questionário ativo
6. `b0b43a4` Decisão manual recolhida sobrevive às atualizações da tela
7. `92c0197` Diagnóstico legível no escuro e captura estreita do questionário
8. `a02c2b8` Documenta o questionário de decisão (ADR 0028)
9. `39a596d` Validação de respostas num helper só, com specs que aceitam entrada malformada
10. `4e66d6f` Implementação: Tela melhor de decisão
11. `6170f13` Revisão de convenções da tela de decisão
12. `ac57114` CI verde: Tela melhor de decisão
13. `6be207f` Telas (e2e): Tela melhor de decisão
14. `bc83e01` Documentação: índice da ADR 0028 e resumo para revisão

Todas as mensagens estão em português e descrevem o que cada commit faz. Esta etapa acrescenta o commit "Entrega: Tela melhor de decisão" com este arquivo.

## Verificação
- `make ci` na etapa CI Verde: exit 0 (compile, format, deps.unlock, credo `--strict`, testes com cobertura de 81,40%, dialyzer sem erros).
- `make e2e`: exit 0, conforme a etapa de Telas.
- Nesta etapa não houve merge nem mudança de código, então o CI não foi rodado de novo.

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

Documentação: ADR nova `docs/adr/0028-questionario-de-decisao.md` (já no índice de `docs/README.md`); ADR 0022 atualizada; spec `docs/specs/maquina-de-estados-tarefa.md`; guia `docs/guias/ui-petal.md`.

### Protocolo e runners antigos
O protocolo não mudou. `perguntas` entra na saída estruturada que o agente devolve, e não no contrato `Hello`/`Job`/`JobEvent`, então runners antigos funcionam. A saída antiga com `opcoes` continua aceita e vira uma pergunta única.

### Riscos e o que olhar com mais atenção
- **Schema do `--json-schema`:** `perguntas` entra no schema base de todas as etapas. Se o CLI recusar alguma construção, todas as etapas quebram. Evitei `if/then`, e vale conferir numa execução real.
- **Análise automática custa dinheiro:** `max_budget_usd: 1` e 10 min por falha. Sem `created_by_user` ou sem criador válido, não há análise (log no `Logger`) e a decisão manual segue disponível.
- **Concorrência em `decide/5`:** o lock na tarefa e o cancelamento da análise em curso.
- **Análise tardia ou cancelada:** `analysis_finished/1` só age se a pausa ainda é a mesma.
- **Cobertura de borda:** o placeholder do campo "Outro" fica cortado na tela estreita (só visual).

### Como verificar
- `make ci > /tmp/ci.log 2>&1; echo $?`
- `make e2e FILE=tests/decision-questionnaire.spec.ts`, e `make e2e` completo.
- `make e2e.shots FILE=tests/decision-questionnaire.spec.ts` para as capturas clara e escura.
- Manual: bloqueie uma etapa que devolva `perguntas`, responda no painel da tarefa e confira "Responder e continuar". Abra a mesma tarefa em outra aba e veja a atualização ao vivo. Force uma falha e veja "o agente está analisando a falha…" e depois o diagnóstico com as perguntas.

## Status
ok — branch pronta para revisão, sem push e sem PR aberto por esta etapa.
