# Plano — Integração com Forgejo e GitHub

> Versão 0.1 — 06/11/2026
> Decisões: [ADR 0034](../adr/0034-integracoes-com-hosts-git.md) e
> [ADR 0035](../adr/0035-credencial-git-por-job.md). Formatos e regras:
> [`specs/integracoes.md`](../specs/integracoes.md).

## Objetivo

Um workspace conecta um host git (o Forgejo primeiro, o GitHub depois), vincula
repositórios a projetos e define gatilhos. Uma issue vira tarefa escrita pela IA e o fluxo
acontece no host: a issue mostra o andamento (reação, comentário de status, labels), o PR
recebe um status por etapa e as pessoas conversam pela issue e pelo PR.

## Fases

A entrega é uma branch só, `feat/integracoes-forges`, com um commit por fase e um único PR
no fim. Cada fase começa pelos testes e fecha com o `make ci` verde; as que têm tela
também com `make e2e` e `make e2e.shots`.

| Fase | Entrega |
|---|---|
| 0 | Documentação: este plano, os ADRs 0034 e 0035 e a spec |
| 1 | Fundação no domínio: `Vault` (a cifra dos segredos extraída), presença dos runners no domínio, esquemas de `Integrations`, o behaviour `Provider` e o cliente do Forgejo, credenciais (token e OAuth com rotação), conexões, repositórios e gatilhos |
| 2 | Telas: Integrações (lista, formulário com token e OAuth, detalhe da conexão, repositório e gatilhos), o callback do OAuth e o Forgejo falso do e2e |
| 3 | Ingestão: o endpoint do webhook, o registro de entregas, o processamento, a triagem com auto-aprovação ligada à issue, a reconciliação e a tela de entregas com reprocessamento |
| 4 | Retorno no host e PR pelo control plane: o estado desejado (labels, comentário de status, commit status, PR) e o `PrText` no protocolo |
| 5 | Credencial git por job: o campo do protocolo, o helper do runner, a renovação e o status da etapa no modo `runner` |
| 6 | Conversa pelo host: comandos em comentário e eventos do PR (review vira correção, merge encerra) |
| 7 | GitHub App: instalação, token por job, Checks, reentrega, e a migração e remoção do gatilho legado do projeto |
| 8 | Guias, as capturas das telas e a validação na instância própria do Forgejo |

## Como se testa

- **Domínio e web:** HTTP com `Req.Test` e um Forgejo falso em memória
  (`test/support/fake_forgejo.ex`); a presença dos runners por um módulo de teste; os
  payloads reais do Forgejo e do GitHub como fixtures.
- **Runner:** o servidor Forgejo dos testes do runner, agora também servindo git por HTTP
  para o push com a credencial do job.
- **e2e:** um Forgejo falso em Node, iniciado com o Playwright, e webhooks assinados
  enviados pelo próprio spec, como o host faria.
- **Na instância real:** conectar a instância própria com um usuário-bot, vincular o
  repositório do PipeMaestro, pôr a label numa issue e acompanhar até o PR pronto; desligar
  o webhook e conferir que a reconciliação pega a issue.
