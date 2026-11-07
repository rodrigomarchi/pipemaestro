# 0044 — Central de notificações no top bar

- **Status:** aceita
- **Data:** 07/11/2026
- **Relacionadas:** [ADR 0001](0001-biblioteca-de-componentes.md), [ADR 0005](0005-pipelines-e-tarefas.md), [ADR 0029](0029-questionario-de-decisao.md)

## Contexto

Quando uma tarefa pausava ou terminava, toda tela do workspace mostrava um toast e,
com a aba em segundo plano, uma notificação do navegador. Os dois eram efêmeros: quem
não estava numa tela do workspace perdia o aviso. Fora do board, nada mostrava o que
estava rodando naquele momento.

## Decisões

1. **Duas coisas diferentes no mesmo sino.**
   - **Em andamento** é derivado e nunca guardado
     (`PipeMaestro.Notifications.active_executions/2`). Mostra as tarefas `running`,
     `awaiting_decision` e `queued` e as propostas sendo escritas, cada uma com etapa,
     runner, criador e tempo decorrido.
   - **Notificações** é uma caixa persistente por pessoa e por workspace (tabela
     `notifications`). Tem os tipos: tarefa aguardando decisão, concluída, falhou,
     cancelada, proposta pronta e proposta que falhou. Sobrevive a reload e a novo login.
2. **Destinatários.**
   - Uma tarefa avisa o criador e o dono da decisão, sem repetir a mesma pessoa, e só
     se ainda forem membros do workspace.
   - Se nenhum deles for membro (tarefa vinda de issue, criador que saiu), avisa os
     admins do workspace.
   - Ninguém lê nem marca a notificação de outra pessoa ou de outro workspace: o escopo
     fica na consulta.
3. **`task_merged` e `task_merge_blocked`** vão para as mesmas pessoas da tarefa,
   quando a plataforma faz o merge do PR ou desiste dele, com o motivo no corpo
   ([ADR 0045](0045-merge-automatico-do-pr.md)).
4. **`proposal_ready` e `proposal_failed` vão para quem pediu a proposta**, quando ela
   termina com sucesso (para revisar) ou falha (para saber que não chegou a lugar
   nenhum e pode ser pedida de novo). O erro da execução vai no corpo. Ficam de fora:
   - a análise de uma falha, que vira o questionário da tarefa, já notificada como
     pausada;
   - a proposta de tarefa auto-aprovada que virou tarefa: não há o que revisar, e a
     tarefa avisa por conta própria;
   - a proposta cancelada: não é falha, e esta decisão não a cobre.
5. **Retenção.** A `PipeMaestro.Maintenance` apaga as notificações lidas há mais de 30
   dias (`:notifications_days`). As não lidas ficam.
6. **Um tópico próprio para o que roda** (`notifications:activity:<workspace>`).
   - `Tasks` e `Jobs` publicam `{:executions_changed, workspace_id}` a cada mudança de
     uma tarefa ou de uma proposta.
   - O hook das telas (`PipeMaestroWeb.NotificationHooks`) consome essa mensagem e a
     interrompe.
   - Ele não assina `tasks:workspace`: as telas que já assinam esse tópico receberiam
     cada mensagem em dobro, e as que não tratam `{:task_updated, _}` quebrariam.
   - A lista é reconsultada uma vez a cada rajada de mudanças, com debounce de 300 ms.
7. **O toast e a notificação do navegador continuam.** Eles avisam na hora quem está
   na tela; a caixa guarda o histórico. Os três saem do mesmo evento da tarefa.
8. **O painel é um LiveComponent no layout** (`PipeMaestroWeb.NotificationCenter`).
   - Aberto ou fechado, aba, "Minhas/Todas", filtro e páginas são estado dele:
     abrir e fechar o painel não toca no estado da página.
   - As abas não usam `?aba=`, porque um overlay não muda a URL da página de baixo.
   - A página `/notifications` guarda o filtro em `?filtro=`.
9. **O ponto pulsante do sino indica trabalho do agente**: tarefa ou proposta rodando
   ou na fila. Uma tarefa que espera uma pessoa aparece em "Em andamento", mas não
   acende o ponto.
10. **Tempos no cliente.** O hook JS `Elapsed` atualiza o tempo decorrido e o relativo a
   partir de `data-since`. O servidor renderiza o primeiro valor e não mantém timer.

11. **Eventos novos entram caso a caso, nunca por padrão.** Cada evento da plataforma
    que passar a avisar pela caixa precisa de uma linha nesta ADR, com o motivo.
    - Eventos de runner e de integração entram só quando exigem ação de quem os
      recebe (um runner que parou e precisa de atenção, uma integração que pede
      reconexão). Um evento informativo fica de fora.
    - Esses avisos vão para **todos os membros** do workspace, não só para quem
      configurou o runner ou a integração.

## Como acrescentar um tipo

1. Acrescente o valor ao `Ecto.Enum` de `PipeMaestro.Notifications.Notification`. A
   coluna é texto, então não há migração.
2. Crie a função de criação em `PipeMaestro.Notifications` e chame-a no contexto onde o
   fato acontece.
3. Dê ícone e cor ao tipo em `PipeMaestroWeb.NotificationComponents.kind_style/1`. Um
   tipo sem entrada usa o sino genérico.

## Consequências

- Toda tela do workspace repassa `notification_center` a `Layouts.app`, como já faz
  com `pending_decisions`. Um teste percorre as rotas do workspace para pegar a tela
  que esquecer.
- Cada mudança de tarefa ou proposta custa uma consulta indexada por tela aberta do
  workspace, limitada pelo debounce. A migração cria o índice `tasks(workspace_id,
  status)` para ela.
