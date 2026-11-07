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
| 03 | [Roadmap do orquestrador](plano/03-roadmap-orquestrador.md) | v0.3 — 03/11/2026 |
| 04 | [Integração com Forgejo e GitHub](plano/04-integracao-forges.md) | v0.1 — 06/11/2026 |
| 05 | [Telemetria do runner](plano/05-telemetria-do-runner.md) | v0.2 — 06/11/2026 |

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
| 0009 | [Perfis de permissão, credencial do agente e operação do runner](adr/0009-permissoes-credencial-e-operacao-do-runner.md) | Perfis substituídos pelo 0018 |
| 0010 | [Conversa com a tarefa: texto ao vivo, intervenções, notificações e reexecução](adr/0010-conversa-com-a-tarefa.md) | Aceita |
| 0011 | [Decisões registradas, contexto por pipeline, orçamento por tarefa e pipelines em YAML](adr/0011-decisoes-contexto-orcamento-e-portabilidade.md) | Aceita |
| 0012 | [Uso, papéis, auditoria, manutenção, alertas e segredos](adr/0012-uso-papeis-auditoria-e-segredos.md) | Aceita |
| 0013 | [Distribuição e entrega no git e no GitHub](adr/0013-distribuicao-e-entrega-no-git.md) | Aceita |
| 0014 | [As pendências do roadmap: paralelo, webhook, outbox, prazos e acabamentos](adr/0014-pendencias-do-roadmap.md) | Aceita |
| 0015 | [Auditoria da execução do claude](adr/0015-auditoria-da-execucao.md) | Aceita |
| 0016 | [Esquema de versão do runner e do control plane](adr/0016-esquema-de-versao.md) | Aceita |
| 0017 | [Linha do tempo compacta: faixas de ícones e painéis](adr/0017-linha-do-tempo-compacta.md) | Aceita |
| 0018 | [Etapas autônomas: permissões totais e sem aprovação entre etapas](adr/0018-etapas-autonomas.md) | Aceita |
| 0019 | [O nome PipeMaestro](adr/0019-o-nome-pipemaestro.md) | Aceita |
| 0020 | [Binários do runner gerados em contêiner e publicados no deploy](adr/0020-binarios-do-runner-no-deploy.md) | Aceita |
| 0021 | [Propostas de pipeline e projeto geradas pelo agente](adr/0021-propostas-de-pipeline-pelo-agente.md) | Aceita |
| 0022 | [Propostas do agente como mecanismo geral](adr/0022-propostas-do-agente-como-mecanismo-geral.md) | Aceita |
| 0023 | [Runner na versão da plataforma](adr/0023-runner-na-versao-da-plataforma.md) | Aceita |
| 0024 | [Resumo da execução e métricas do agente](adr/0024-resumo-da-execucao-e-metricas-do-agente.md) | Aceita |
| 0025 | [Atualização automática do runner](adr/0025-atualizacao-automatica-do-runner.md) | Aceita (padrão alterado pela 0038) |
| 0026 | [Deploy pelo Forgejo e main protegida](adr/0026-deploy-pelo-forgejo-e-main-protegida.md) | Aceita |
| 0027 | [Entrega em PR no Forgejo](adr/0027-entrega-em-pr-no-forgejo.md) | Aceita |
| 0028 | [Teto de custo só quando configurado](adr/0028-teto-de-custo-so-quando-configurado.md) | Aceita |
| 0029 | [Questionário de decisão](adr/0029-questionario-de-decisao.md) | Aceita |
| 0030 | [Screenshots reais da landing](adr/0030-screenshots-reais-da-landing.md) | Aceita |
| 0031 | [Auto-aprovação da tarefa escrita com IA](adr/0031-auto-aprovacao-da-tarefa-escrita-com-ia.md) | Aceita |
| 0032 | [Sem ruas sem saída](adr/0032-sem-ruas-sem-saida.md) | Aceita |
| 0033 | [Contrato entre o harness e o agente](adr/0033-contrato-entre-harness-e-agente.md) | Aceita |
| 0034 | [O projeto é runner + pasta e a escolha única de onde o trabalho roda](adr/0034-o-projeto-e-a-escolha-de-onde-o-trabalho-roda.md) | Aceita |
| 0035 | [Versão própria do runner](adr/0035-versao-propria-do-runner.md) | Aceita |
| 0036 | [Integrações com hosts git](adr/0036-integracoes-com-hosts-git.md) | Aceita |
| 0037 | [Credencial git por job](adr/0037-credencial-git-por-job.md) | Aceita |
| 0038 | [Atualização automática por padrão](adr/0038-atualizacao-automatica-por-padrao.md) | Aceita |
| 0039 | [Telemetria do runner](adr/0039-telemetria-do-runner.md) | Aceita |
| 0040 | [O diagrama é a visão padrão do pipeline](adr/0040-diagrama-do-pipeline.md) | Aceita |
| 0041 | [Continuar a sessão da etapa anterior](adr/0041-continuar-a-sessao-da-etapa-anterior.md) | Aceita |
| 0042 | [Arquivos gerados pela etapa sobem como anexos](adr/0042-arquivos-gerados-pela-etapa.md) | Aceita |
| 0043 | [Runner resiliente a reinícios e à atualização](adr/0043-runner-resiliente-a-reinicios.md) | Aceita |

## Specs

- [Protocolo runner ↔ control plane (v4)](specs/protocolo-runner.md)
- [Integrações com hosts git](specs/integracoes.md)
- [Máquina de estados da tarefa](specs/maquina-de-estados-tarefa.md)

## Guias

- [Instalação: control plane, runners e o primeiro pipeline](guias/instalacao.md)
- [Deploy em produção (pipemaestro.app)](guias/deploy.md)
- [Conectar um Forgejo](guias/integracoes-forgejo.md)
- [O GitHub App da plataforma](guias/github-app.md)
- [Phoenix 1.8](guias/phoenix.md)
- [UI com petal_components](guias/ui-petal.md)
- [Testes de tela (e2e) e auditoria visual](../e2e/README.md)
