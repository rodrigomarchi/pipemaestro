# 04 — Revisão de convenções

Revisei o diff contra `origin/main` (`apps/*/lib`, docs, e2e) com a lista de convenções.
Não encontrei nada a corrigir; não há commit de código nesta etapa.

- **Plano e testes:** as quatro partes do plano (questionário no bloqueio, análise na falha,
  respostas estruturadas, componente único) têm teste de domínio, de LiveView e spec e2e.
- **`@spec` e `@moduledoc`:** presentes nos módulos novos (`Tasks.Questionnaire`,
  `Proposals.AnalysisKind`, `QuestionnaireComponents`, `QuestionnaireLive`).
- **LiveViews finas:** `QuestionnaireLive` só guarda o estado da tela e delega a validação a
  `Tasks`/`Questionnaire`.
- **Petal e `data-testid`:** os `div` e `label` crus são layout e cartões selecionáveis, o que
  o `docs/guias/ui-petal.md` já documenta. Todo elemento tocado leva `data-testid`.
- **`handle_info`:** sem catch-all que engula mensagem; as cláusulas de ignorar são de
  mensagens nomeadas.
- **Fronteiras e cobertura:** sem dependência cruzada no umbrella; `mix.exs` não mudou, então
  não há exclusão nova de cobertura.
- **Comentários e prosa:** descrevem o código; não há contagens na prosa.
- **`make ci.quick`:** exit 0.
