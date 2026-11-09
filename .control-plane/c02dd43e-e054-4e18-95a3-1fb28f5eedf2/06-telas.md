# Telas (e2e)

## O que mudou na tela

Uma tela mudou: **Uso e limites** (`UsageLive`), com:
- a aba nova **Qualidade** (`?aba=qualidade`);
- o filtro de projeto na barra do topo.

Os arquivos são `usage_live.ex` e `usage_quality_components.ex`, mais o spec
`e2e/tests/usage-quality.spec.ts` e o Page Object `e2e/pages/UsagePage.ts`.

## Estados conferidos (`make e2e.shots FILE=tests/usage-quality.spec.ts`, claro e escuro)

As imagens estão em `$CP_FILES_DIR/screenshots/`:

- `01-quality-empty`: nenhum PR no período. Mostra o aviso de estado vazio. O retrabalho e
  as pausas aparecem vazios com mensagem própria. O select de projeto só aparece quando há
  projetos.
- `03-quality-accepted-with-changes`: um PR com commit de pessoa, mergeado.
  - Os quatro cartões de taxa e a linha de PRs entregues, mediana até o merge e rodadas de
    review.
  - A tabela por pipeline, a barra da semana, o retrabalho por etapa e as etapas que mais
    pausam (vazio).
- `04-quality-filtered`: filtros de pipeline e projeto aplicados, com os números mantidos.

Contraste, alinhamento e textos cortados estão corretos nos dois modos, e os cartões, as
tabelas e o `record_empty` seguem as telas vizinhas e `docs/guias/ui-petal.md`.

## O que ajustei

- **Tabela "Por pipeline":** as taxas estavam espremidas na primeira coluna ("Correção de
  bug · 0% sem alteração · 100% com alteração"). Agora têm colunas próprias, **Sem
  alteração** e **Com alteração**, cada uma com seu `data-testid`
  (`usage-quality-pipeline-<nome>-clean` e `-changed`).
  - O spec e o teste de LiveView passaram a ler esses ids.
  - `UsagePage` ganhou `pipelineChanged(nome)`.
- **Barra da semana:** com 0% sem alteração, a barra fica cinza e não verde, que sugeria um
  bom resultado.

## Resultado

- `make e2e.typecheck`: ok.
- `usage_live_test.exs`: passa.
- `make e2e` (suíte inteira): saiu 0, todos os specs passam.
- Na primeira rodada inteira, `runner-telemetry.spec.ts` falhou com timeout ao preencher o
  nome do workspace no backoffice. É uma corrida de carga fora da tela mexida. O spec passa
  isolado e a segunda rodada inteira passou, sem mudança de código entre elas.
