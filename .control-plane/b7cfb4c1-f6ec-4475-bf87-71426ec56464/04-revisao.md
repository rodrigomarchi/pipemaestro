# 04 — Revisão de convenções

Diff revisado: `git diff $(git merge-base HEAD main)`.

## Resultado

Nenhuma correção foi necessária. `make ci.quick` passou (código de saída 0).
`make ci` completo (com Dialyzer) e `make e2e` não foram rodados nesta etapa.

## Verificações

- **Plano cumprido:** `Downloads` no protocolo, `SelfUpdate` e `Update.handle/2` no runner, `--auto-update` em `start` e `login`, `service install` gravando `--auto-update` para o binário Burrito, ADR 0025, guias, spec do protocolo e e2e (fluxo E). Cada critério de aceite tem teste em `self_update_test.exs`, `update_test.exs`, `service_test.exs`, `runner_tasks_test.exs`, `downloads_test.exs` ou no e2e.
- **`@spec` e `@moduledoc`:** presentes em `Downloads`, `SelfUpdate`, `Update` e `Output`.
- **LiveViews:** nenhuma tocada. A mudança na web é só `RunnerComponents` (alvos vindos do protocolo) e um `@moduledoc`.
- **Petal/Tailwind e `data-testid`:** nenhuma tela nova. Os ids existentes (`runner-download-<alvo>`) foram mantidos.
- **Comentários:** descrevem o código, não a mudança.
- **`handle_info` catch-all:** nenhum introduzido.
- **Fronteiras:** o runner continua dependendo só do protocolo. `Downloads` não depende de nada do umbrella.
- **Cobertura:** nenhuma exclusão de módulo nova. O `test_ignore_filters` em `mix.exs` só impede que `test/support/` seja tratado como teste.
- **Contagens na prosa:** nenhuma encontrada nos docs do diff.
- **Protocolo:** o formato das mensagens e o `protocol_version` não mudam. Runners antigos continuam compatíveis.

## Pendências

- Validação manual com o binário real (reexecução no terminal, Ctrl+C), já listada no plano como fora do CI.
