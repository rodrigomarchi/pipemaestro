# Etapa 6 — Telas (e2e)

A tarefa mudou telas (`apps/pipe_maestro_web/lib` e `e2e`), então rodei o e2e.

## Resultado

- `make e2e.typecheck`: ok.
- `make e2e` (suíte inteira, uma vez, na árvore final): exit 0, todos os specs passam.
- O spec novo `task-files-retention.spec.ts` cobre os três fluxos do plano (política e cota no
  backoffice, recusa por cota, anexos e eventos podados). Os specs vizinhos
  (`task-files`, `backoffice-workspaces`, `job-execution`, `task-stage-panel`) também passam.

## Telas e estados conferidos (claro e escuro, `make e2e.shots`)

- **Backoffice, formulário do workspace:** os quatro campos novos (dias dos anexos, cota em MiB, dias dos
  eventos, destino depois do prazo), com rótulos, ícones e ajuda alinhados aos campos vizinhos.
- **Backoffice, detalhe do workspace:** card "Anexos e retenção" com o uso contra a cota, a barra de
  progresso e as duas políticas em palavras.
- **Tela de Uso:** o mesmo bloco, somente leitura, abaixo do conteúdo principal; uso pequeno aparece
  como "< 0,1 MiB de 1 MiB".
- **Tentativa da etapa:** aviso de arquivos recusados pela cota, separado do aviso de arquivos que não
  chegaram; lista de anexos podados (nome, ícone e "removido pela retenção", sem link); aba Passos com o
  aviso de retenção e os eventos só com metadados.
- **Aba Anexos do fim:** anexos podados com o nome e o badge.

## Ajustado

- Na etapa de implementação o texto do agente podado deixava um balão vazio e o uso pequeno aparecia
  como "0,0 MiB". Os dois foram corrigidos antes desta etapa.
- Aqui, o `BackofficePage.setRetention` ganhou `shot`, para capturar o formulário preenchido. A captura é
  só do formulário (a de página inteira saía minúscula, com a lista ao fundo). O formulário rola dentro do
  modal, então a captura corta o fim dele; os campos, o select e os botões não foram cortados na tela.

As screenshots estão em `$CP_FILES_DIR/screenshots/` e não vão para o git.
