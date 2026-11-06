# Revisão de convenções

Diff revisado contra `origin/main`. Nada a corrigir.

- Plano cumprido; critérios 1–5 têm teste (`update_test`, `runner_tasks_test`, `service_test`, `main_test`), o 6 foi verificado na etapa 3 (`make e2e`).
- `@spec`/`@moduledoc`: nada novo sem eles (só `consent/2`, privada, mudou).
- Sem LiveView, Petal ou `data-testid` envolvidos; sem `handle_info` novo.
- Fronteiras do umbrella intactas: só o runner mudou, sem dependência nova; protocolo inalterado.
- Comentários descrevem o código; sem exclusão de cobertura; sem contagens na prosa.
- `grep auto-update`: `--auto-update` só aparece como compatibilidade.
- `make ci.quick`: passa (exit 0). Dialyzer não rodado; o tipo de `consent/2` não mudou.
