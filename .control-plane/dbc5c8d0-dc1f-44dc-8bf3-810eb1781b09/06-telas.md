# Etapa 6 — Telas (e2e)

**Nenhuma tela mudou.** `git diff --stat $(git merge-base HEAD origin/main) -- apps/pipe_maestro_web/lib apps/pipe_maestro_web/assets e2e`
não listou nenhum arquivo. A tarefa alterou só `Makefile`, `Dockerfile`, a ADR 0016,
`docs/guias/instalacao.md` e um teste do `protocol`.

Por isso não rodei specs, `make e2e.shots` nem a suíte e2e. O gate também pula o e2e
quando os caminhos de tela estão sem mudanças.
