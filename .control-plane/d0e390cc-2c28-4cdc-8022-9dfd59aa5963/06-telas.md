# Telas (e2e)

A tarefa mudou telas (LiveViews de projetos, tarefas, execuções, propostas, board, decisões, Pull requests e uso).

## E2E
`make e2e > /tmp/e2e.log 2>&1; echo $?` → **0**, 23 testes passando na primeira execução. Nenhuma correção necessária.

## Screenshots conferidas (claro e `-dark`)
Specs rodados com `make e2e.shots`: `projects`, `task-pipeline`, `job-execution`, `agent-proposals`, `pipeline-proposal` (todos saíram com 0).
Abertas e auditadas, nos dois temas, as telas de `projects.spec.ts`:
- **Formulário de projeto**: Nome, Runner e Diretório (selects) alinhados; texto de ajuda legível; botão "Analisar com IA".
- **Lista de projetos**: runner, diretório e estado online; estados vazios dos comandos exibidos como "–"; toast de confirmação.
- **Formulário de nova tarefa**: seletor único "Projeto" (nome · runner:diretório) com a dica de que ele decide runner e diretório.
- **Tarefa em execução**: projeto com link, diretório de trabalho e retrato do projeto.
- **Revisão da proposta de projeto**: verificações, formulário preenchido, trilha do agente.

Contraste, alinhamento, textos e consistência com as telas vizinhas e com `docs/guias/ui-petal.md`: sem problemas.

## Observação
Nas capturas de página inteira, a barra fixa "Salvar" do formulário aparece sobre o card "Contexto para os agentes". É a barra fixa já existente rodando fora do viewport da captura, não um defeito introduzido aqui.

## Ajustes
Nenhum código alterado nesta etapa.
