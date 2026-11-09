# Revisão de convenções

Diff revisado: `git diff $(git merge-base HEAD origin/main)`. A branch contém `origin/main`.

## Plano e critérios de aceite

- Todos os critérios têm teste: remoção só do que é da tarefa (`claude_sessions_test.exs`, `job_runner_test.exs`), `worktree:usage` com as sessões (`disk_test.exs`), evento sem `error` na remoção (`job_runner_test.exs`), evento no protocolo, no domínio e na web.
- A versão testada do CLI (2.1.319) está no moduledoc de `ClaudeSessions` e no ADR 0053.

## Convenções

- `@moduledoc` e `@spec` presentes em tudo o que é novo; as funções privadas não precisam.
- Nenhuma LiveView ganhou regra de negócio (só um rótulo em `LogTab.kind_label/1`); sem tela nova, então sem `data-testid` nem Playwright.
- Fronteiras do umbrella intactas: o runner só usa `protocol` e a stdlib; o domínio só ganhou um grupo e leitura de `task_id`.
- Nenhum `handle_info` catch-all, nenhuma exclusão de cobertura, nenhuma contagem na prosa dos docs.
- Comentários descrevem o código.

## Corrigido

- `JobRunner.clean_sessions/3`: `ClaudeSessions.forget/2` rodava fora do `try`. Uma falha ao apagar o marcador derrubaria a `Task` antes de `worktree:removed`, contra a regra de que a limpeza nunca vira erro da remoção. Agora o `forget` está dentro do `try`, e uma falha vira o evento `claude_sessions_not_found` com `reason: "error"`. `job_runner_test.exs` continua verde.
