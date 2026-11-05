# 0033 — Contrato entre o harness e o agente

- **Status:** aceita
- **Data:** 05/11/2026
- **Substitui:** o passo de commit da entrega (ADR 0013 e 0027)

## Contexto

Uma auditoria da linha do tempo de uma etapa mostrou o harness (o control plane e o
runner) mexendo no git em paralelo ao agente:
- fazia um `git add --all` de tudo o que sobrava;
- fazia o push sem `fetch` e sem conferir a branch;
- reescrevia o título e a descrição do PR a cada etapa;
- criava o worktree a partir do checkout local, sem `fetch`;
- os artefatos iam para o repositório e chegavam à `main`.

O agente roda com todas as permissões e com as credenciais da máquina. Os prompts, o
`CLAUDE.md` e o `AGENTS.md` são livres. Ele pode fazer commit, push, abrir PR, trocar de
branch ou parar no meio de um merge, e pessoas podem fazer commit no PR. Cada suposição do
harness sobre o estado do repositório era um conflito à espera de acontecer.

## Decisão

**O harness verifica de forma determinística e é a fonte da verdade; o agente faz o
trabalho no git e corrige; o prompt só carrega fatos e o contrato, nunca proibições.**
`PipeMaestro.Tasks.Contract` é a fonte única do contrato.

- **Quem faz o commit é o agente.** O runner não faz commit.
- **Verificações da plataforma** (`checks`, em `PipeMaestroRunner.Checks`) rodam depois
  do agente e antes dos gates, com o mesmo mecanismo deles: uma que falha volta ao agente
  como feedback na tentativa seguinte e, quando as tentativas acabam, vira uma decisão.
  Elas conferem:
  - o trabalho na branch da tarefa;
  - nenhum merge, rebase ou conflito pela metade;
  - a branch contém o origin, então o push é fast-forward;
  - nada sem commit (fora o que o setup copiou ou criou, e a pasta dos artefatos);
  - nenhum valor dos segredos do workspace nas mudanças;
  - o artefato da etapa commitado e, na última etapa, os artefatos fora da branch.

  Elas aparecem, só para leitura, no editor de pipeline e, com o selo "plataforma", na
  tela da tarefa.
- **Antes do agente** (`PipeMaestroRunner.RepoState.sync/2`), o runner:
  - faz o `fetch` da branch;
  - faz o fast-forward só quando ele não pode perder nem misturar nada;
  - fora isso, conta ao agente o que achou, numa seção "Estado do repositório" do prompt:
    uma divergência, outra branch, uma operação em andamento ou um `index.lock`.

  Também regrava, vindos do control plane, os artefatos anteriores que faltam no disco.
- **A entrega é idempotente e converge** com o que o agente já fez:
  - o push de um `HEAD` já verificado (um no-op se o agente já tinha feito o push);
  - o PR aberto da branch é adotado, seja de quem for;
  - o harness escreve só o bloco dele na descrição, entre
    `<!-- pipemaestro:inicio -->` e `<!-- pipemaestro:fim -->`;
  - o título é escrito só na criação, e depois só o prefixo de rascunho muda.
- **Worktree novo:** nasce de `origin/<branch padrão>` depois de um `fetch`, não do
  checkout local.
- **Artefatos:** ficam em `.control-plane/<tarefa>/` no worktree.
  - Cada etapa commita o seu: o PR mostra o andamento, e outro agente pode continuar da
    branch.
  - A última etapa os tira da branch sem apagar do disco (`git rm -r --cached`).
  - O control plane guarda todos, para auditoria.
- **Protocolo 4:** `checks`, `sync`, `artifacts`, e a `delivery` sem `commit_message` e
  com `pr.block`. O runner antigo é recusado e se atualiza sozinho.

## Consequências

- Um agente que esquece algo custa uma tentativa, com o motivo exato, em vez de o harness
  varrer o worktree e commitar lixo, arquivos gerados ou segredos.
- O agente ainda pode fazer push na `main` ou force-push: o harness detecta depois (a
  branch não contém o origin), mas só a proteção do forge impede. Tirar as credenciais do
  agente ficou de fora, por escolha.
- **Etapas em grupo** dividem o mesmo worktree ao mesmo tempo, então nenhuma delas pode
  ser verificada sozinha: continuam sem entrega e sem verificações, uma limitação
  conhecida.
- Pipelines com entrega `commit` passam a significar "commits do agente, conferidos", sem
  push.
