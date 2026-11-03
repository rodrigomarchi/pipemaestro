# 0010 — Conversa com a tarefa: texto ao vivo, intervenções, notificações e reexecução

- **Status:** aceita
- **Data:** 03/11/2026
- **Roadmap:** Marco 2, itens 4, 5, 8, 9, 10 e 11, de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)

## Contexto

Com a tarefa legível (ADR 0007), faltava conversar com ela enquanto roda e ser avisado
quando ela precisa de alguém. Também faltava refazer trabalho sem recomeçar do zero e
ver cada runner em detalhe.

## Decisões

1. **Texto do agente ao vivo, efêmero.** O runner roda o CLI com
   `--include-partial-messages` e repassa o texto em escrita como `job:delta`.
   - No máximo um envio a cada 250 ms, com até 4 KB do fim do texto.
   - A mensagem não passa pela outbox, não é guardada e não é reenviada: a
     mensagem completa chega depois como evento.
   - O servidor só confere que o job é do runner e está rodando, e retransmite
     pelo PubSub do job.
2. **Instrução no meio da etapa espera** (questão em aberto 3 do roadmap).
   - Uma mensagem enviada com a tarefa rodando fica pendente e entra no prompt da
     próxima tentativa ou etapa, junto com outras pendentes e com as instruções de
     uma decisão.
   - A etapa em execução não é interrompida: cancelar e refazer continua
     disponível para quem quiser.
3. **Pausar depois desta etapa e refazer a partir de uma etapa.**
   - A pausa pedida vale uma vez: quando a etapa atual passa, a tarefa espera
     decisão.
   - Refazer a partir da etapa N vale para tarefas que não estão rodando e ainda têm
     o worktree. N roda uma nova tentativa e as seguintes rodam de novo na sequência;
     cada etapa continua a numeração das suas tentativas.
4. **Notificações por um tópico de eventos da tarefa** (`{:events, workspace_id}`).
   - Quando uma tarefa espera decisão, termina, falha ou é cancelada, toda página do
     workspace mostra um toast. O hook de `on_mount` é o mesmo do contador de
     decisões.
   - Se a aba está em segundo plano e a pessoa permitiu, aparece também uma
     notificação do navegador, e o clique leva à tarefa.
5. **Reexecutar e duplicar.**
   - **Reexecutar:** cria uma tarefa com o mesmo pedido, pipeline, runner e
     diretório, usando o pipeline como está agora.
   - **Duplicar:** abre o formulário de nova tarefa preenchido, para mudar o que
     for preciso.
   - A lista de tarefas ganha busca por título e pedido.
6. **Execuções avulsas continuam.** O item 10 do roadmap propunha transformá-las em
   tarefas de "Prompt único". Elas ficam como estão: rodam no workdir do runner, sem
   diretório, e servem para prompts rápidos e para depurar o runner. O lugar
   principal de acompanhar trabalho são as tarefas e o board.
7. **Página do runner** (`/w/:slug/runners/:id`), ao vivo:
   - o agente e a credencial;
   - a capacidade em uso;
   - os worktrees e o disco;
   - os jobs em execução e na fila;
   - os diretórios oferecidos.

## Consequências

- O protocolo ganha `job:delta` (runner → control plane), sem resposta.
- A tarefa ganha `pending_instructions` e `pause_requested`.
