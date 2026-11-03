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
| 03 | [Roadmap do orquestrador (antes do git)](plano/03-roadmap-orquestrador.md) | v0.1 — 03/11/2026 |

## Decisões (ADR)

| # | Decisão | Status |
|---|---|---|
| 0001 | [Biblioteca de componentes de UI: petal_components](adr/0001-biblioteca-de-componentes.md) | Aceita |
| 0002 | [Identidades, workspaces e backoffice](adr/0002-identidades-e-workspaces.md) | Aceita |
| 0003 | [Login e conexão do runner](adr/0003-conexao-do-runner.md) | Aceita |
| 0004 | [Execução de jobs no runner](adr/0004-execucao-de-jobs-no-runner.md) | Aceita |
| 0005 | [Pipelines no control plane e tarefas no runner](adr/0005-pipelines-e-tarefas.md) | Aceita |
| 0006 | [Runner paralelo, ambiente quente e entrega confiável](adr/0006-runner-paralelo-e-ambiente-quente.md) | Aceita |
| 0007 | [Visualização da tarefa: Markdown, diff local, linha do tempo, board e decisões](adr/0007-visualizacao-da-tarefa.md) | Aceita |
| 0008 | [Projetos, gates por comando, regras e retentativa com feedback](adr/0008-projetos-gates-e-feedback.md) | Aceita |
| 0009 | [Perfis de permissão, credencial do agente e operação do runner](adr/0009-permissoes-credencial-e-operacao-do-runner.md) | Aceita |
| 0010 | [Conversa com a tarefa: texto ao vivo, intervenções, notificações e reexecução](adr/0010-conversa-com-a-tarefa.md) | Aceita |
| 0011 | [Decisões registradas, contexto por pipeline, orçamento por tarefa e pipelines em YAML](adr/0011-decisoes-contexto-orcamento-e-portabilidade.md) | Aceita |

## Specs

- [Protocolo runner ↔ control plane (v3)](specs/protocolo-runner.md)
- [Máquina de estados da tarefa](specs/maquina-de-estados-tarefa.md)

## Guias

- [Phoenix 1.8](guias/phoenix.md)
- [UI com petal_components](guias/ui-petal.md)
- [Testes de tela (e2e) e auditoria visual](../e2e/README.md)
