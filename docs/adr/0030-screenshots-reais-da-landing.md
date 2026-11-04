# 0030 — Screenshots reais da landing

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

A landing explicava a plataforma com diagramas em Tailwind, mas quem chegava não via o
produto. Mostrar telas exige imagens que pareçam de um time de verdade (nomes, tarefas,
custos plausíveis), que acompanhem as telas quando elas mudarem e que não revelem dados
de quem as gerou.

## Decisão

- **Um diretor e2e gera as imagens.** `e2e/director/landing.spec.ts` monta o workspace
  Nimbus pela interface, com um runner real, e fotografa as telas em claro e escuro
  (`make landing.shots`). Roda à parte, só com `E2E_DIRECTOR=1`, num banco e2e recriado.
- **As imagens são versionadas** em `apps/pipe_maestro_web/priv/static/images/landing/`,
  com nomes fixos; rodar de novo sobrescreve os mesmos arquivos. Não são geradas no CI
  nem no deploy.
- **CLI de vitrine separado do `fake_claude`.** `e2e/director/support/showcase_claude`
  imprime o mesmo `stream-json` do CLI real e do `fake_claude`, com uma sessão rica
  (ferramentas, edições, `make test`, OTLP). O `fake_claude` continua sendo a fixture das
  specs, que dependem das saídas exatas dele.
- **O dado das telas é um módulo.** `PipeMaestroWeb.LandingShots` declara nome, textos,
  `alt` e tamanho em pixels de cada tela; o template e os testes leem dele, e
  `LandingShotsTest` falha se um arquivo faltar, divergir do tamanho declarado ou passar
  de 600 KB.

## Alternativas descartadas

- **Gerar no CI ou no deploy:** o diretor precisa de Postgres, do servidor e de um runner
  real, e leva minutos; imagens que mudam a cada deploy também não passam por revisão.
- **Só ilustrações:** não mostram o produto, que é o objetivo.
- **Um gancho opt-in no `fake_claude`:** funcionaria, mas mistura vitrine com fixture de
  teste e arrisca as specs que dependem dele.

## Consequências

- Uma mudança numa tela mostrada na landing pede `make landing.shots` e a revisão das
  imagens no PR.
- O protocolo do runner não muda: o diretor só troca `CLAUDE_BIN` do runner que inicia.
