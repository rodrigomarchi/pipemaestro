# Etapa 6 — Telas (e2e)

## Telas alteradas
A tarefa mudou a página de Executores (`RunnersLive`, `RunnerComponents`), o modal
"Conectar um runner" e o endpoint `/version` (sem tela), mais o spec
`runner-connection` e o page object `RunnersPage`.

## Verificação
- `make e2e`: 23 testes passaram (exit 0), sem correção necessária.
- `make e2e.shots FILE=tests/runner-connection.spec.ts`: passou; screenshots
  abertas nas versões clara e escura.

## Estados conferidos (claro e `-dark`)
- `03-runner-online`: tabela com a versão do runner (2026-11-03.02) diferente do
  rodapé da plataforma (2026-11-04.02), como esperado.
- `04-runner-downloads`: "Versão 2026-11-03.02, a que esta plataforma pede".
- `05-runner-connect-downloads`: modal com o selo "A plataforma pede o runner na
  versão …", alinhado e com contraste bom nos dois temas, consistente com as
  telas vizinhas. O comando `curl` longo rola dentro do bloco, como já era.

## Ajustes
Nenhum: não houve mudança de código nesta etapa.
