# Revisão de convenções

Revisei o diff contra `origin/main` (código, testes, docs e e2e). Está tudo conforme o plano e os critérios de aceite têm teste.

## Verificado, sem ajuste

- **Plano e aceite:** cada critério tem teste (`tasks_test`, `pipelines_test`, `proposals_test`, `pipeline_live_test`, `pipeline_components_test`, `task_live_test` e o spec `pipeline-auto-analysis`). Nada ficou de fora.
- **Convenções:**
  - Não há função pública nova, então `@spec` e `@moduledoc` não se aplicam; o `@moduledoc` de `Pipeline` e o de `Tasks` descrevem o campo.
  - As LiveViews não ganharam regra de negócio: a decisão fica em `Tasks.await/3`.
  - O switch usa o `<.field type="switch">` do Petal, e `pipeline-auto-analysis` e `pipeline-summary-no-analysis` seguem a nomenclatura do `e2e/README.md`.
  - Não há `handle_info` novo, exclusão de cobertura, dependência cruzando fronteira do umbrella, nem contagem em prosa.
- **Protocolo e runner:** o protocolo não mudou. A única mudança no runner é a correção do cache de gates descrita em `03-implementacao.md`.
- **Formulário:** `Form.initial_params/1` não lista `auto_analysis`, ao contrário de `auto_merge`. O campo é lido do dado do pipeline, e o teste de LiveView prova que o valor salvo reabre corretamente, então deixei como está.

## Corrigido

- O comentário de `Tasks.auto_analysis?/1` dizia "como antes" e narrava a mudança. Agora descreve o código: só um `false` explícito no retrato desliga a análise.
- Em `docs/specs/maquina-de-estados-tarefa.md`, o parágrafo "Análise automática" estava com uma linha longa e quebra torta. Reformatei.

## Verificação

Só comentário e doc mudaram. Rodei `tasks_test` (103 passam) e `make ci.quick` (saída 0).
