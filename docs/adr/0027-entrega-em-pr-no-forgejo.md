# 0027 — Entrega em PR no Forgejo

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

Com `delivery: pr` (ADR 0013), o runner faz commit de cada etapa que passa, faz o push
da branch da tarefa e mantém um pull request em rascunho, que fica pronto na última
etapa. O PR e o comentário na issue usavam só o `gh`, do GitHub.

O PipeMaestro passou a ser desenvolvido no próprio PipeMaestro, num repositório cujo
`origin` é um Forgejo privado, com a `main` aceitando mudanças só por PR (ADR 0026). Sem
suporte ao Forgejo, o pipeline usava a entrega `commit`: o agente fazia o push na última
etapa e uma pessoa abria o PR.

## Decisão

- **O destino vem do `origin`.** Se o host do `remote.origin.url` (lido antes de
  qualquer `insteadOf`) responde como Forgejo ou Gitea em `/api/v1/version`, o PR e o
  comentário vão pela API dele (`PipeMaestroRunner.Delivery.Forgejo`). GitHub, caminho
  local ou qualquer outro host continuam com o `gh`.
- **A consulta da versão é feita já com a credencial.** Um Forgejo privado não responde
  nem a versão a quem não fez login.
- **Credencial:** a mesma do `git push` para o host (`git credential fill`, sem nunca
  perguntar nada). Sem ela, vale um `FORGEJO_TOKEN` nos segredos do workspace, ou no
  ambiente do runner. Dos segredos do job, só esse chega à entrega.
- **Rascunho é o prefixo `WIP: ` no título**, a convenção do Forgejo. Marcar como pronto
  é tirar o prefixo. O PR da branch é achado entre os abertos pela `head`, porque um nome
  de branch com barra (`cp/...`) não cabe na rota `/pulls/{base}/{head}`. A base é a
  branch padrão do repositório.
- **O PR existe desde a primeira etapa.** A entrega da primeira etapa que passa abre o
  rascunho, as seguintes atualizam título e descrição, e a última o deixa pronto. O
  agente não faz push nem abre PR: a entrega é da plataforma.

## Consequências

- Um pipeline com `delivery: pr` num repositório do Forgejo mostra o andamento da tarefa
  no PR enquanto ela roda, e o merge do PR pronto publica (ADR 0026).
- O runner precisa de uma credencial do git para o host que o deixe abrir PRs. Um runner
  como serviço, sem acesso ao chaveiro, precisa do `FORGEJO_TOKEN`.
- O protocolo não muda: só a forma como o runner entrega.
