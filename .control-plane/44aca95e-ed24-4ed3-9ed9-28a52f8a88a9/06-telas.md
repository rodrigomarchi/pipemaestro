# Telas (e2e)

A tarefa mudou telas: o formulário de pipeline (`pipeline_live/form*.ex`), `task_components.ex`, `audit_components.ex` e `task_live/show.ex`. O spec novo é `e2e/tests/pipeline-stage-context.spec.ts`.

## Resultado
- `make e2e`: 30 testes passaram, saída 0.
- `make e2e.shots FILE=tests/pipeline-stage-context.spec.ts`: saída 0. Conferi as versões clara e `-dark`.

## Telas e estados conferidos
- **Formulário de pipeline, etapa 1 com "Continuar a etapa anterior" (estado de erro):** o select "Contexto" fica com borda vermelha e a mensagem "a primeira etapa não tem uma etapa anterior para continuar". O texto de ajuda aparece abaixo e há contraste suficiente nos dois temas.
- **Formulário de pipeline, etapa com contexto de continuação (estado válido):** o campo "Contexto" fica alinhado com os demais campos de "Avançado". O seletor de agente e o de grupo em paralelo mantêm o layout.
- Sem texto cortado nem desalinhamento. O visual é coerente com as telas vizinhas e com `docs/guias/ui-petal.md`.
- O cabeçalho e a barra "Salvar" aparecem no meio da imagem porque a captura é de página inteira e esses elementos são fixos. Não é um defeito.

## Ajustes
Nenhum. Nenhum código mudou nesta etapa.
