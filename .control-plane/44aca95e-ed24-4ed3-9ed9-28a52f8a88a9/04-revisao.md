# Revisão de convenções

Diff revisado contra `origin/main`.

## Conferido, sem achados
- Plano cumprido: cada critério de aceite tem teste (domínio, protocolo, runner com CLI falso, web e e2e); ADR 0041 criado e ADR 0004 aponta para ele; spec do protocolo atualizada.
- `@spec`/`@moduledoc` presentes no que é novo; LiveViews só delegam; seletor é Petal (`icon_field`) e o selo usa `badge`.
- `data-testid` em tudo que os specs tocam (`stage-context-N`, `stage-advanced-N`, `stage-run-session-*`).
- Sem `handle_info` catch-all novo, sem dependência cruzando fronteira (runner só usa `protocol`), sem exclusão de cobertura, sem contagens em prosa.
- Compatibilidade do protocolo: campos opcionais e aditivos, atrás da capacidade `resume_session`; sem decisão humana pendente.

## Corrigido
- `e2e/tests/pipeline-stage-context.spec.ts`: o fluxo estava `[todo]` no cabeçalho, mas o spec roda e passa; agora `[done]`.

## Validação
- `make ci.quick` verde.
