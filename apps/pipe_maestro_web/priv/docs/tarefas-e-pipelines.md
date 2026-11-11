A plataforma tem poucas peças. Entendê-las ajuda a escrever pedidos melhores e a montar
pipelines do jeito do seu time.

## Tarefa

Um pedido de trabalho: um título, uma descrição em Markdown, o pipeline que vai executá-lo
e o projeto onde o código vive. Nasce de três jeitos: alguém cria na plataforma, o agente
escreve a partir de uma ideia ([Escrever com IA](/docs/agente-ajudante)) ou uma issue do
GitHub ou do Forgejo dispara um gatilho.

Uma tarefa está **na fila**, **executando**, **aguardando decisão**, **concluída**,
**falhou** ou **cancelada**. O board separa as tarefas por esses estados.

## Pipeline

A receita: as etapas, em ordem, que toda tarefa dele percorre. **A ordem é do pipeline, não
do agente**: o agente não pula etapas nem decide o próximo passo.

O pipeline é genérico de propósito, para servir a qualquer projeto do workspace. O que é
específico de um repositório fica nele mesmo, no `CLAUDE.md` ou no `AGENTS.md`, que toda
etapa lê. Cada vez que você salva o pipeline, a versão sobe; uma tarefa guarda a versão com
que começou, então editar nunca muda uma tarefa em andamento.

Um pipeline também pode levar:

- **Prompt de sistema** que vale para todas as etapas.
- **Servidores MCP** (logs, métricas, o seu issue tracker), com tokens vindos dos Segredos.
- **Subagentes** que uma etapa pode usar.
- **Teto de custo por tarefa**: passou dele, a tarefa pausa para uma decisão.
- **Entrega**: nenhuma, um commit por etapa ou pull request (com ou sem merge automático).
- **Analisar falhas com IA** (ligado por padrão): numa pausa por falha, o agente diagnostica
  e faz as perguntas antes de você chegar.

Os pipelines se exportam e importam em YAML, para versionar ou copiar entre workspaces.

{{tela:pipeline}}

## Etapa

Uma etapa é um prompt para o agente, com variáveis como `{{tarefa.descricao}}`,
`{{projeto.teste}}` e `{{projeto.notas}}`. Ela também define:

| Configuração | Para quê |
|---|---|
| Tentativas | quantas vezes a etapa tenta antes de pedir ajuda (padrão 2) |
| Modelo | haiku, sonnet ou opus, por etapa |
| Tempo limite | passado ele, o runner para o agente e a tentativa falha (padrão 60 min) |
| Orçamento | um teto de custo para a etapa, quando alguém define |
| Gates | comandos que precisam passar (ou falhar, com `!`) depois do agente |
| Regras | pausam a tarefa quando a saída estruturada diz algo (`risco == alto`) |
| Grupo | etapas seguidas do mesmo grupo rodam ao mesmo tempo, no mesmo worktree |
| Contexto | começar do zero (lendo só os artefatos) ou continuar a sessão da etapa anterior |
| Agente | rodar como um subagente do repositório (`.claude/agents/`) ou do pipeline |

## Artefato

Toda etapa termina escrevendo um **artefato**: um Markdown com o que fez, o que decidiu e o
que deixou para a próxima. É ele que a etapa seguinte lê ao começar, e é o que você lê para
entender o trabalho sem abrir o diff. Arquivos que o agente produz (uma imagem, um CSV)
ficam como **anexos** da tarefa.

## Gate

O gate é a prova. Depois do agente, o runner roda os comandos de teste e lint do projeto (e
os gates da etapa). **Quem decide se uma etapa passou são os testes, não a opinião do
agente.** Um gate falhou? A etapa tenta de novo, já sabendo o que deu errado. Esgotou as
tentativas? A tarefa pausa e pede uma [decisão](/docs/decisoes).

## Projeto

Um diretório de um runner com os comandos de **setup**, **teste** e **lint**, os arquivos a
copiar para cada worktree (um `.env` de teste, por exemplo) e as **notas para os agentes**.
Uma tarefa escolhe o projeto, e com ele o runner e o diretório onde vai rodar.

## Runner e worktree

O [runner](/docs/runner) roda na sua máquina. Para cada tarefa, ele cria um **worktree git**
do diretório do projeto, num branch próprio, e roda o setup nele. As etapas trabalham ali,
e o seu diretório de trabalho não é tocado. Várias tarefas rodam ao mesmo tempo, cada uma
no seu worktree.

## Entrega: commit, PR e merge

Com entrega em commit, o agente faz o commit do que mudou em cada etapa, e a plataforma
confere que nada ficou de fora antes de seguir. Com entrega em pull request, o runner também
envia o branch e mantém um PR em rascunho, que fica pronto depois da última etapa. Os
artefatos saem do branch na última etapa, então o PR só leva código. O diretório precisa de
um `origin` no GitHub (o runner usa o `gh` da máquina) ou num Forgejo.

Com **Fazer o merge do PR sozinha** ligado, num repositório
[vinculado](/docs/github-e-forgejo), a plataforma espera os checks do repositório
passarem e faz o merge (merge, squash ou rebase). Um check vermelho ou um conflito vira uma
etapa de correção, até um limite; depois disso, o merge fica parado e quem cuida da tarefa é
avisado. Desligado, que é o padrão, o merge fica com você.
