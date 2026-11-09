# Revisão de convenções

Revisei o diff contra `origin/main` (`git diff $(git merge-base HEAD origin/main)`), sem
mudança de código. Só a documentação mudou, então não rodei suíte.

## O que conferi

- **Plano e critérios de aceite:** todos têm teste.
  - Critérios 1 a 4: `conversation_test.exs` e `pr_outcomes_test.exs`, nos fakes de Forgejo e
    GitHub, com idempotência de merge, review e `observe/1`.
  - Critérios 5 e 6: `usage/quality_test.exs`, mais a aba em `usage_live_test.exs`.
  - Critério 7: `e2e/tests/usage-quality.spec.ts`, com os screenshots claros e escuros
    conferidos na etapa anterior.
  - Critérios 8 e 9: o ADR 0053 e as specs documentam a mudança; `make ci.quick` e o
    Dialyzer passaram na etapa anterior.
- **`@spec` e `@moduledoc`:** presentes em `PrOutcome`, `PrOutcomes`, `UsageQualityComponents`,
  `Usage.quality/3`, `Provider.pr_commits/3` e `ProviderSupport.pr_commit/1`. Os helpers
  privados e os macros não precisam.
- **LiveView:** `UsageLive` só delega a `Usage` e a `Projects`. A validação do filtro de
  projeto segue o filtro de pipeline que já existia, sem regra de negócio.
- **UI:** `.card`, `.table`, `record_list`, `record_card`, `record_metric` e `.icon_field`
  do Petal e do `ListComponents`. O único markup cru é o gráfico de barras por semana, que
  espelha o "Custo por dia" da mesma tela.
- **`data-testid`:** em tudo que o spec e o teste de LiveView tocam, no padrão
  `<área>-<coisa>`, com a chave natural nos registros.
- **Comentários:** descrevem o código, sem narrar a mudança.
- **`handle_info` catch-all:** nenhum novo. Os `rescue` ficam no `guarded/2` do Reconciler, que
  já loga.
- **Fronteiras:** `protocol` e runner intocados. O `Usage` lê `PrOutcome`, do mesmo app.
- **Cobertura:** nenhuma exclusão nova.
- **Contagens na prosa:** não há nos docs de produto. O "250 commits" do GitHub é um limite do
  host.

## O que corrigi

- `docs/specs/maquina-de-estados-tarefa.md` não citava `Decision.origin` nem o desfecho do PR.
  Agora cita os dois, com link para o ADR 0053.

## Pontos aceitos

- `Feedback.write_pr` passa um `issue_feedback` só com o `pr_number` para `PrOutcomes.ready/1`.
  A função só lê o número, então funciona; um parâmetro explícito seria mais limpo, mas não
  vale a mudança agora.
- O desfecho de um PR integrado enquanto a tarefa ainda não terminou não é criado, porque
  `ready/1` exige `succeeded`. O ADR 0053 já diz que só contam tarefas entregues.
