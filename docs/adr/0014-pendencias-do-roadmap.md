# 0014 — As pendências do roadmap: paralelo, webhook, outbox, prazos e acabamentos

- **Status:** aceita
- **Data:** 03/11/2026
- **Roadmap:** seção 5 de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)

## Contexto

Os seis marcos estavam feitos (ADRs 0006 a 0013), com uma lista de itens deixados para
depois. Este ADR registra como cada um foi resolvido, e os dois que continuam
pendentes.

## Decisões

1. **Etapas em paralelo (fan-out).**
   - Etapas seguidas com o mesmo `group` formam um passo: começam juntas, cada uma
     com seu gate e suas retentativas.
   - O passo fecha quando nenhuma etapa dele roda mais. Se todas passaram, a tarefa
     segue; se alguma bloqueou ou esgotou as tentativas, pausa com os motivos de
     todas.
   - "Refazer" repete só as etapas que não passaram, e "seguir" pula o passo
     inteiro.
   - Cada etapa do grupo lê os artefatos de antes do passo, não os das irmãs.
   - No runner, os jobs marcados `parallel` da mesma tarefa rodam juntos no worktree.
   - A primeira etapa não pode estar num grupo, porque é ela que cria o worktree.
   - Etapas paralelas não fazem entrega no git: commits simultâneos no mesmo
     worktree disputariam o índice.
   - O diff de uma etapa paralela pode incluir o que as irmãs mudaram ao mesmo tempo.
2. **Webhook do GitHub por label.**
   - O projeto ganha repositório, label e pipeline de gatilho. As tarefas ficam em
     nome de quem configurou o gatilho.
   - O webhook do workspace (`/api/github/webhook/<workspace>`) confere a assinatura
     HMAC com o segredo `GITHUB_WEBHOOK_SECRET`.
   - Uma issue com a label cria a tarefa num runner online que ofereça o diretório
     do projeto, uma vez por issue enquanto a tarefa não terminar.
3. **Outbox que sobrevive a restart.**
   - O desfecho de um job (`job:finished`) e a remoção de worktree ficam também num
     arquivo, ao lado das credenciais.
   - Depois de um restart, o runner os reenvia e conta esses jobs como em execução,
     para a reconciliação não os falhar.
   - Os eventos intermediários continuam só em memória.
4. **Prazos e responsáveis das decisões.**
   - Uma tarefa que pausa tem quem decide (quem a criou, reatribuível) e um prazo de
     24 horas.
   - A página de Decisões mostra os dois e filtra "só as minhas".
   - Uma decisão atrasada vira alerta no board.
5. **Limite de tarefas simultâneas por workspace** (configurado no backoffice).
   - Passado o limite, a tarefa nova entra como `queued` ("Na fila").
   - Quando uma tarefa deixa de rodar (termina ou pausa), a mais antiga da fila
     começa.
   - Retomar por decisão humana não espera vaga.
6. **Destaque de sintaxe no navegador.** Um realçador próprio e pequeno, num hook do
   LiveView, marca palavras-chave, textos, comentários e números das linguagens
   comuns. As cores vêm de classes com variantes clara e escura. O `mdex` só realça
   no servidor com o `lumis` e um pacote por linguagem, peso que não se paga aqui.
7. **Linha do tempo:**
   - tokens de cada turno do agente;
   - leituras e buscas seguidas agrupadas ("Leu 3 arquivos e fez 1 busca");
   - filtros (tudo, agente, ferramentas, erros) no passo a passo.
8. **Pequenos complementos:**
   - num diretório sem git, a etapa mostra os arquivos novos, alterados e removidos
     (por conteúdo, sem diff de linhas);
   - o `doctor` confere o `gh` e o login dele;
   - o sinal de cancelamento cai para o próprio processo quando o grupo ainda não
     existe. Um processo recém-criado pode ter o TERM bloqueado, e por isso o
     cancelamento manda KILL em seguida.

9. **Binário único do runner (Burrito).**
   - A release `cp_runner` gera um executável por plataforma (macOS arm64 e x86_64,
     Linux x86_64 e arm64), com o Erlang dentro (`make runner.binary`).
   - No binário, a release sobe em vez de rodar `eval`, e o CLI do Elixir leria os
     argumentos como scripts. Por isso o `start/2` do runner roda o comando e encerra
     a VM.
   - O Burrito publica ERTS por versão do OTP, não por patch, e só troca os binários
     e os NIFs. O binário é gerado no OTP 28.5 para que os apps do OTP da release e o
     NIF do `crypto` de cada alvo coincidam.
   - A versão do binário leva o commit, porque ele se descompacta uma vez por versão
     e reaproveitaria um payload antigo.
   - O `service install` de dentro do binário aponta para o próprio binário.

## Continua pendente

- **GitHub App com token por tarefa:** exige registrar um app no GitHub e instalá-lo
  nos repositórios. Até lá, o runner usa o `gh` de quem o roda.
