# Telas (e2e)

A tarefa mudou telas (`task_live/show.ex`, `job_file_components.ex`, `TasksPage.ts`, `task-files.spec.ts`).

## Verificação
- `make e2e`: 30 testes passaram, exit 0, incluindo `task-files.spec.ts`.
- `make e2e.shots FILE=tests/task-files.spec.ts`: screenshots claras e `-dark` abertas e conferidas.

## Telas e estados conferidos (claro e escuro)
- Aba **Anexos** da tarefa: grupo "Executar · tentativa 1", miniatura da imagem (a.png, 70 B) e link do CSV (dados/r.csv, 18 B); contraste, alinhamento e contagem na aba corretos.
- Execução da etapa: seção "Arquivos" com miniatura e link de download; sem textos cortados.
- Nada precisou de ajuste; nenhuma mudança de código nesta etapa.
