# 04 — Revisão de convenções

Diff revisado contra `origin/main`.

## Resultado

- Plano cumprido: runner com versão própria (`Git.runner/1`), `version_check/1` contra
  `Version.runner_version/0`, deploy que só reconstrói quando `VERSION` muda, tela de
  runners com `data-testid="runners-expected-version"`, `/version` com `runner_version`.
- `@spec`/`@moduledoc`: presentes em tudo o que é novo.
- LiveViews: `RunnersLive` só repassa `Version.runner_version()`; sem regra de negócio.
- Petal: o novo `expected_version` usa `.badge`.
- `data-testid`: `runners-expected-version` segue o padrão kebab-case de `e2e/README.md`.
- Sem `handle_info` catch-all novo, sem dependência cruzando fronteira (o cálculo fica no
  `protocol`), sem exclusão de cobertura, sem contagens em prosa.

## Correções

- Linhas de documentação longas demais em `Runners.outdated?/2` e `HealthController.version/2`
  foram quebradas.

## Validação

`make ci.quick` passou (saída 0).
