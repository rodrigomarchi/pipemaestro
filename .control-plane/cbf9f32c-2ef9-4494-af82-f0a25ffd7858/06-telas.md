# Telas (e2e)

## Telas alteradas
- Formulário de pipeline (`pipeline_live/form.ex`): textos do teto de custo por tarefa e por etapa.
- Lista de pipelines (`pipeline_live/index.ex`): rótulo "Sem limite de custo".

## Verificação
- `make e2e`: 17 passaram, saída 0. Nenhuma correção foi necessária.
- `make e2e.shots FILE=tests/pipeline-proposal.spec.ts`: abri `04-proposal-pipeline-form` nas versões clara e `-dark`.
  - Teto por tarefa e por etapa aparecem vazios, com o texto de ajuda "Vazio é sem limite".
  - Contraste, alinhamento e textos sem corte estão corretos nos dois temas, e o formulário segue o padrão das telas vizinhas.
  - A barra fixa e o toast que cobrem parte do contexto do pipeline vêm da captura de página inteira, não da tarefa.
- A lista de pipelines não tem screenshot em nenhum spec; a mudança nela é só o texto do rótulo.

## Ajustes
Nenhum. Não houve mudança de código nesta etapa.
