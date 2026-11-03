# 0006 — Runner paralelo, ambiente quente e entrega confiável

- **Status:** aceita
- **Data:** 03/11/2026
- **Roadmap:** Marco 1, itens 1 a 5, de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)
- **Complementa:** [0004](0004-execucao-de-jobs-no-runner.md) (execução de jobs) e
  [0005](0005-pipelines-e-tarefas.md) (pipelines e tarefas)

## Contexto

Com o ADR 0005, uma tarefa percorre um pipeline num worktree próprio, mas o runner
ainda tinha três limitações:

- executava um job por vez, então uma tarefa travava as outras;
- cada worktree nascia sem dependências nem build, e a primeira etapa pagava a
  instalação;
- eventos e desfechos enviados durante uma queda de conexão se perdiam, e um job que
  terminava offline era dado como perdido no join.

## Decisões

1. **Paralelismo por lugar de execução.** O runner executa até `capacity` jobs (o
   valor anunciado no `Hello`). Jobs que dividem um lugar esperam um pelo outro, na
   ordem: as etapas de uma tarefa (o worktree dela), os jobs num diretório sem
   worktree e os jobs avulsos (o workdir). O preparo do lugar (criar o worktree, o
   setup) roda fora do processo do `JobRunner`, para não segurar a saída dos outros
   jobs.
2. **Tarefas no mesmo repositório rodam em paralelo** (questão em aberto 1 do
   roadmap). Cada uma tem seu worktree. O isolamento de serviços locais (banco, portas)
   fica a cargo do projeto, por exemplo com um banco por worktree, até existir a
   configuração de projeto (Marco 3), que poderá limitar a concorrência por diretório.
3. **Ambiente quente por cópia *copy-on-write*.** Quando o worktree nasce, o runner
   clona do checkout os diretórios caros que o git não carrega e depois roda o comando
   de setup. A clonagem usa `cp -c` no APFS e `--reflink` no Linux, com cópia comum
   como fallback.
   - **O que copiar** (questão em aberto 2): detecção automática (`deps`, `_build`,
     `node_modules`, `.venv`, `venv`, `vendor/bundle`, `target`) enquanto não há
     projetos. O job pode trazer a lista e o comando em `setup`, que é o que a
     configuração de projeto vai preencher.
   - Um setup que falha falha o job e remove o worktree, para que a próxima tentativa
     recomece do zero.
   - O tempo de "ambiente preparado" aparece na tentativa que criou o worktree.
4. **Worktrees só saem a pedido.** Remover automaticamente ao concluir poderia apagar
   mudanças não commitadas: commit e push ficam a critério do prompt até a integração
   com git.
   - A tarefa terminada oferece "Remover worktree". O pedido é reenviado a cada join até
     o runner confirmar, e o runner recusa se a tarefa ainda tem job.
   - O runner informa quantos worktrees guarda e o espaço que ocupam, e a página de
     runners mostra.
   - Uma retenção automática (remover após N dias) fica para os jobs de manutenção
     (Marco 4).
5. **Outbox em memória.** O runner guarda cada mensagem de job até a resposta do canal
   e reenvia o que falta depois de cada join. Um job com mensagens não confirmadas conta
   como em execução no `Hello`. A outbox não sobrevive a um restart do runner; isso fica
   para o runner como serviço (Marco 1, item 9).
6. **Tempo máximo por etapa.** A etapa tem `timeout_minutes` (padrão 60). Ao estourar,
   o runner encerra o grupo de processos e a tentativa falha, entrando na regra de
   retentativas.

## Consequências

- Some a lacuna de eventos aceita no ADR 0004, exceto num restart do runner.
- O protocolo ganha campos opcionais (`setup` e `timeout_ms` no `Job`, `setup` no
  `job:finished`) e as mensagens de worktree. Como são aditivos e nada está publicado,
  a versão continua 3. Detalhes em
  [`protocolo-runner.md`](../specs/protocolo-runner.md) §4.
- Uma tarefa de longa duração não bloqueia mais as outras, mas consome uma vaga de
  `capacity` enquanto roda. A tela de nova tarefa mostra a ocupação de cada runner.
