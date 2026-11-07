# Revisão de convenções

Diff revisado contra `origin/main`. Nada precisou de correção.

- **Plano:** abas, contadores ao vivo, filtros na URL e `?aba=` inválido estão implementados e cobertos em `board_live_test.exs` e nos specs e2e ajustados.
- **`@spec` e `@moduledoc`:** presentes em `BoardLive` e nos módulos `board_live/*_tab.ex`.
- **LiveView fina:** `BoardLive` só orquestra carga e eventos. A leitura de dados vem do domínio (`Tasks`, `Runners`, `RunnerTelemetry`).
- **Petal:** `tabs`, `tab` e `badge` são componentes Petal. O Tailwind cru restante é de layout e já existia no board.
- **`data-testid`:** `board-tabs`, `board-tab-<id>` e `board-tab-count-<id>` seguem `e2e/README.md`.
- **`handle_info`:** todas as mensagens assinadas têm cláusula explícita, sem catch-all.
- **Fronteiras do umbrella:** o domínio não mudou, e a web usa apenas contextos existentes.
- **Cobertura:** nenhuma exclusão nova.
- **Comentários e contagens:** descrevem o código, sem contagens na prosa de docs.
- **`make ci.quick`:** passou (saída 0).
