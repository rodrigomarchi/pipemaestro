# 0034 — Integrações com hosts git (Forgejo e GitHub)

- **Status:** aceita
- **Data:** 06/11/2026
- **Plano:** [`04-integracao-forges.md`](../plano/04-integracao-forges.md)
- **Spec:** [`integracoes.md`](../specs/integracoes.md)
- **Substitui:** o webhook do GitHub por label do [ADR 0014](0014-pendencias-do-roadmap.md) e
  os campos de gatilho do projeto (removidos na fase do GitHub App)

## Contexto

Uma issue já podia virar tarefa, mas por pedaços soltos e presos ao GitHub:
- um webhook por workspace, que só tratava `issues.labeled`, processava a entrega dentro da
  própria requisição e não guardava nada;
- o gatilho guardado no projeto, um repositório e uma label por projeto;
- a triagem com IA, que nunca criava a tarefa sozinha;
- o `issue_url`, validado só para `github.com`;
- o PR e o comentário feitos pelo runner com a credencial de quem o roda.

O control plane nunca falava com a API de um host git, e nenhum dos dois hosts retenta um
webhook que falhou: o Forgejo espera 5 s, o GitHub 10 s, e o replay do Forgejo existe só na
interface web.

## Decisões

1. **Conexão por workspace** (`PipeMaestro.Integrations.Connection`).
   - Guarda o provedor (`forgejo` ou `github`), a URL da instância, a credencial cifrada
     (`PipeMaestro.Vault`, o AES-GCM dos segredos), o segredo do webhook gerado pela
     plataforma, o login do bot e a versão do servidor.
   - O Forgejo não tem nada como o GitHub App: a integração sempre age como um usuário. Por
     isso a conexão aceita, desde o início, **o token de um usuário-bot** e **OAuth2**
     (authorization code com PKCE, escopos sempre explícitos, porque sem eles o token
     sai com acesso total).
   - O refresh token do Forgejo vale um uso só: a renovação acontece numa transação com
     lock na linha da conexão, gravando o par novo nela.
   - O GitHub usa um GitHub App da plataforma, com token de instalação.
2. **Quem chama a API do host é escolha da conexão** (`api_mode`).
   - `control_plane` (padrão): o control plane faz reação, comentário, labels, commit status
     e PR. O runner só faz o push.
   - `runner`: para instâncias que o SaaS não alcança (mas que conseguem enviar webhooks
     para ele). O runner continua abrindo o PR e comentando (ADR 0027), agora com a
     credencial da conexão, e também posta o status da etapa. Nesse modo só existe o
     gatilho por label, porque os outros dependem de verificar pela API a permissão de
     quem disparou; pôr uma label já exige permissão de escrita.
3. **Repositório vinculado a um projeto** (`LinkedRepo`).
   - O vínculo cria as labels da plataforma que faltam e, quando a credencial pode,
     o webhook do repositório. Sem permissão, a tela mostra a URL e o segredo para criar à
     mão.
4. **Gatilhos por repositório** (`Trigger`): label adicionada, comando em comentário
   (`/pipemaestro`, opcionalmente com o nome do pipeline) e toda issue nova.
   - O padrão é a **triagem com IA e auto-aprovação**: o agente escreve a tarefa e escolhe
     o pipeline, e a tarefa nasce sozinha ([ADR 0031](0031-auto-aprovacao-da-tarefa-escrita-com-ia.md)).
     Se ele tiver perguntas, a proposta espera revisão e as perguntas vão para a issue.
   - Guardas em cada gatilho: só autores com permissão de escrita (padrão), um limite de
     disparos por hora e uma pessoa do workspace em nome de quem a tarefa nasce.
     "Qualquer autor" exige confirmação explícita, porque o texto da issue entra no prompt.
5. **Toda entrega é registrada antes de ser processada** (`Delivery`).
   - O endpoint confere a assinatura, grava a entrega (única por id da entrega na
     conexão), responde em milissegundos e processa fora da requisição.
   - O processamento é uma sequência determinística de passos, e cada um que encerra deixa
     o motivo na entrega. A tela de entregas mostra o motivo e permite reprocessar.
   - O estado de cada issue (`IssueState`) guarda o retrato das labels, para achar a label
     **adicionada** (o Forgejo manda a lista inteira), e os gatilhos que já dispararam, para
     que nem a reconciliação nem uma entrega repetida disparem duas vezes.
   - A issue é relida pela API antes de agir: a ordem das entregas não é garantida.
6. **Reconciliação periódica** (`Reconciler`), porque nenhum host garante a entrega.
   - Busca as issues alteradas desde o último sync de cada repositório e passa cada uma
     pelo mesmo processamento, além de reprocessar as entregas que esperavam um runner.
   - No GitHub, também reentrega o que não ficou OK.
   - Comentários não são reconciliados: um comando perdido custa pouco a repetir.
7. **O retorno no host é um estado desejado** (`Feedback`).
   - A partir da tarefa, calcula as labels de status, um comentário de status (um só, editado
     no lugar), um commit status por etapa no último commit empurrado e o PR (o bloco da
     plataforma com `PipeMaestroProtocol.PrText`, o título só na criação, como no
     [ADR 0033](0033-contrato-entre-harness-e-agente.md)).
   - Aplica só o que mudou. Uma falha da API não pausa a tarefa: fica marcada e a
     reconciliação tenta de novo. A falha do push continua pausando (ADR 0027).
   - Comentários novos, que notificam as pessoas, só quando a tarefa espera uma decisão,
     quando o PR fica pronto e quando ela é cancelada.
8. **Conversa pelo host.** Comandos num comentário (`seguir`, `refazer`, `cancelar`,
   `corrigir`, `responder`, `pausar`) chamam as mesmas funções da tela, em nome da pessoa do
   gatilho, com o login do host registrado na decisão. Um review pedindo mudanças num PR
   pronto vira a etapa "Correção N".
9. **A presença dos runners chega ao domínio por um behaviour** (`PipeMaestro.Runners.Presence`),
   implementado pela web (`PipeMaestroWeb.RunnerStatus`), porque o processamento das
   entregas e a reconciliação rodam fora de uma requisição.

## Consequências

- O `issue_url` aceita a issue de qualquer host; a tarefa guarda também o repositório
  vinculado e o número da issue.
- O domínio passa a depender do `Req` e ganha um `Task.Supervisor` para o processamento.
- O segredo `GITHUB_WEBHOOK_SECRET` deixa de ser usado; como os segredos chegam aos runners,
  quem o tinha deve apagá-lo.
- A credencial git de cada job está no [ADR 0035](0035-credencial-git-por-job.md).
