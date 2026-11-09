# Etapa 4 — Revisão de convenções

Revisado o diff contra `origin/main` (`Makefile`, `Dockerfile`, ADR 0016, guia de
instalação e o teste novo do `protocol`).

## Conferido, sem achado

- **Plano cumprido**: todos os itens e critérios de aceite têm prova (ExUnit com `mix` e
  `docker` falsos, ou o comando rodado, registrado no artefato 03).
- **Convenções de código**: nenhum `.ex` de `lib/` mudou, então não há `@spec`,
  `@moduledoc` novos a cobrar (o teste tem `@moduledoc`-equivalente: comentário de
  cabeçalho, e é módulo de teste). Sem LiveView, tela, Petal, `data-testid`,
  `handle_info`, protocolo ou fronteiras do umbrella tocados. Sem exclusão de cobertura.
- **Comentários**: descrevem o código (esquema, falha do `mix`, ausência de `.git`), não
  a mudança.
- **Contagens na prosa**: nenhuma.
- **Deploy**: intocado, conferido na etapa 3.

## Corrigido

- ADR 0016: a frase "Para se o cálculo falhar…" estava truncada; agora "Ele para se…".
- Com `ALLOW_UNVERSIONED=1` e só uma versão passada, só a que falta vira `dev+unknown`,
  mas o `Dockerfile`, a ADR e o guia diziam "as duas". Texto ajustado nos três.

Mudou só texto (mensagem e comentário do `Dockerfile`, e docs). Rodei o teste estrutural
do Dockerfile (`image_build_test.exs`, 28 passam). Não rodei `make ci.quick`: nenhum
código Elixir mudou desde o último que passou.
