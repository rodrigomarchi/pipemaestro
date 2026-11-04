# Telas (e2e)

A tarefa mudou código de tela: `runner_components.ex` (a lista de downloads passa a vir de `PipeMaestroProtocol.Downloads`, sem mudar o markup nem o resultado visual), `runner_update.ex` (só documentação), o spec `runner-connection.spec.ts` e o helper `runnerProcess.ts`.

## e2e
- `make e2e` passou (16 testes, código 0).
- `make e2e.shots FILE=tests/runner-connection.spec.ts` passou. As screenshots claras e `-dark` foram abertas.

## Telas e estados conferidos
- Página de Executores com o bloco "Baixar o runner" (04, clara e escura): quatro alvos (macOS Apple Silicon, macOS Intel, Linux x86_64, Linux arm64), versão, bloco de `curl` com o nome do binário vindo de `Downloads.binary_name/1`. Contraste, alinhamento e textos estão corretos.
- Modal "Conectar um runner" (05, clara e escura): passo 1 com os downloads, passos 2 e 3. Está consistente com o guia de UI. A linha longa do `curl` rola na horizontal dentro do bloco de código, como antes da tarefa.
- Demais telas do fluxo (01-03, 06-09): sem mudança de markup, sem regressão visível.

## Ajustes
Nenhum foi necessário. Nenhum código mudou nesta etapa, então não houve novo `make ci.quick` nem commit de código. As screenshots são ignoradas pelo git.
