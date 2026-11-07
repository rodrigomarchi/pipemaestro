# Revisão de convenções

Diff revisado contra `origin/main`.

## Resultado

- Plano cumprido: protocolo aditivo (`files`, `CP_FILES_DIR`, `files_failed`, `PUT` fora do canal), runner, domínio, controllers, tela, e2e, ADR 0041 e spec.
- Critérios de aceite com teste: upload com `fake_claude`, substituição por `(job_id, path)`, 401/404/413/422, runner sem `files`, control plane antigo (`files_failed`), download com `attachment` e isolamento por workspace, spec Playwright.
- `@spec` e `@moduledoc` presentes em tudo o que é novo.
- LiveView (`TaskLive.Show`) só delega a `Jobs.Files`; sem regra de negócio.
- Petal usado onde há primitivo (`alert`, `card`, `link`, `icon`); `figure`/`img` das miniaturas não têm equivalente.
- `data-testid` em miniaturas, links, seções e avisos, no padrão do `e2e/README.md`.
- Fronteiras: o runner depende só de `protocol` (usa `Req`); o domínio não tem web; `:mime` declarado em `apps/pipe_maestro/mix.exs`.
- Sem `handle_info` catch-all novo, sem exclusão de cobertura, sem contagens na prosa.

## Correção feita

- `show.ex`: comentário das abas estava com linha longa; reflowed.

## Validação

`make ci.quick` passou (exit 0).
