# Telas (e2e)

A tarefa mudou duas telas:

- o drawer do pipeline, aba "Entrega" (`form_fields.ex`);
- o resumo do pipeline (`pipeline_components.ex`).

A tela da pausa não mudou.

## Resultado

- `make e2e.typecheck`: saída 0.
- `make e2e.shots FILE=tests/pipeline-auto-analysis.spec.ts`: saída 0.
- `make e2e` (suíte inteira, uma vez): saída 0, 38 testes passaram.

## Capturas conferidas (claro e escuro)

Copiadas para `$CP_FILES_DIR/telas/`:

- `01-pipeline-auto-analysis.png`
- `01-pipeline-auto-analysis-dark.png`

Estado conferido: aba Entrega com o switch "Analisar falhas com IA" desligado.

- O switch fica logo depois do teto de custo e antes da entrega, alinhado à esquerda como os campos vizinhos.
- O rótulo e a ajuda aparecem inteiros, sem texto cortado, com o mesmo estilo da ajuda do teto de custo.
- O contraste do rótulo, da ajuda e do switch está bom nos dois temas, e o foco no switch é visível.
- Nenhum ajuste foi necessário.

O estado "ligado" é o padrão do drawer. O spec confere nele o `toBeChecked`, e o resumo "Sem análise automática de falhas" é conferido por `pipeline-summary-no-analysis` quando está desligado.
