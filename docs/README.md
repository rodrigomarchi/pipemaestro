# Documentação

Documentação de produto e arquitetura da plataforma de pipeline de agentes de IA para engenharia.

## Estrutura

| Diretório | Conteúdo |
|---|---|
| [`plano/`](plano/) | Documentos do plano de produto, numerados em ordem de leitura. |
| [`adr/`](adr/) | Registros de decisões de arquitetura (ADRs), um arquivo por decisão: `NNNN-titulo-curto.md`. |
| [`guias/`](guias/) | Guias de uso de bibliotecas e padrões de código (ex.: Phoenix/LiveView). |
| [`specs/`](specs/) | Especificações técnicas: contrato do protocolo executor ↔ control plane, schema da definição de pipeline, modelo de dados e máquinas de estado. |

## Plano

| # | Documento | Status |
|---|---|---|
| 01 | [Visão de arquitetura](plano/01-visao-arquitetura.md) | Rascunho v0.1 — 03/11/2026 |
| 02 | [Contexto de discovery](plano/02-contexto-discovery.md) | v0.1 — 03/11/2026 |

## Decisões (ADR)

| # | Decisão | Status |
|---|---|---|
| 0001 | [Biblioteca de componentes de UI: petal_components](adr/0001-biblioteca-de-componentes.md) | Aceita |
| 0002 | [Identidades, workspaces e backoffice](adr/0002-identidades-e-workspaces.md) | Aceita |

## Guias

- [Phoenix 1.8](guias/phoenix.md)
- [UI com petal_components](guias/ui-petal.md)
- [Testes de tela (e2e) e auditoria visual](../e2e/README.md)
