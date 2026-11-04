# 0021 — Propostas de pipeline e projeto geradas pelo agente

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

Montar um pipeline exige conhecer o projeto de destino: como instala, testa e faz
lint, onde estão as convenções, como a mudança é entregue. Quem cria o pipeline
precisava descobrir isso sozinho e traduzir em etapas, gates e variáveis. O agente
que roda as etapas já sabe estudar um repositório, e o runner já leva jobs a um
diretório com saída estruturada (`output_schema`).

O agente roda com todas as permissões (ADR 0018). Um job "só de leitura" rodando no
diretório do usuário poderia alterá-lo.

## Decisão

- **Uma proposta é um job.** A tela de pipelines pede um runner online, um dos
  diretórios git dele e o pedido em Markdown. `PipeMaestro.Proposals` cria o job com:
  - instruções que explicam o formato do PipeMaestro (`Proposals.Instructions`): etapas,
    grupos, variáveis, gates, regras e entrega, com um template como exemplo;
  - o pedido de estudar o projeto e **rodar** os comandos de teste e lint que propuser;
  - o JSON Schema da resposta (hoje em `Proposals.PipelineKind`, ver a ADR 0022):
    `analise`, `verificacoes`,
    `projeto` e `pipeline`, este no formato do YAML (`Pipelines.Yaml.from_map/1`);
  - teto de US$ 3 e 20 minutos.
- **A análise roda num worktree descartável.** O campo `scratch` do job faz o runner
  criar `git worktree add --detach` em `<workdir>/scratch/<job_id>`, copiar as
  dependências (copy-on-write) e apagar o worktree quando o job termina. Um worktree
  que sobrou de uma queda é apagado quando o runner sobe, e o git esquece a entrada dele
  na próxima análise do mesmo diretório. Os arquivos de trabalho do diretório do usuário
  não mudam.

  Não é um sandbox. O worktree compartilha o `.git` com o diretório (configuração,
  hooks, refs), e o agente, com todas as permissões, pode escrever fora dele. O prompt
  pede que ele não mexa no git nem saia do worktree. A proteção contra texto hostil é
  outra: a proposta não recebe os segredos do workspace (ADR 0022).
- **Uma capacidade anunciada protege runners antigos.** Um runner anterior descartaria
  `scratch`, que é uma chave desconhecida, e rodaria a análise no próprio diretório. O
  runner passa a anunciar `capabilities: ["scratch"]` no `Hello`, guardado em
  `runners.capabilities`. O control plane só oferece e só aceita runners com a
  capacidade, e mostra os demais como "atualize o runner". O protocolo continua na v3.
- **A pessoa aprova.** A tela da proposta mostra:
  - a análise, as verificações e as etapas;
  - o projeto do diretório, editável. Se o diretório já tem um projeto, ele é atualizado.

  Salvar o projeto abre o formulário de pipeline preenchido com a proposta
  (`?proposta=<job>`), validado como qualquer outro.
- **Uma nova rodada leva a proposta anterior e o comentário da pessoa.**

## Consequências

- O mesmo fluxo serve para qualquer projeto que o runner alcance, sem configuração
  prévia.
- Uma proposta custa uma execução do agente. Ela aparece em Execuções e nas propostas
  recentes da tela de pipelines.
- A capacidade no `Hello` vira o caminho para outros campos novos do job que um runner
  antigo não deve receber.
