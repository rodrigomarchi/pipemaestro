Tudo o que o agente faz fica visível: ao vivo enquanto roda e registrado depois.

## Board

A página inicial do workspace. Ela abre na **visão geral** (o que roda, o que espera
decisão, o que terminou e o custo do período) e se divide em abas: tarefas, decisões,
atividade e runners. Cada aba tem o próprio endereço, então um link abre direto nela.

{{tela:board}}

Um cartão "precisa de atenção" aparece quando um runner fica offline, degradado ou com a
conta do agente perto do limite de uso.

## A página da tarefa

O pipeline, de cima a baixo, com o estado de cada etapa. Abrir uma etapa mostra, ao vivo
enquanto roda:

- o **artefato** que ela escreveu;
- os **arquivos** que mudou no worktree;
- o **passo a passo** do agente: pensamento, cada ferramenta chamada e a saída dela, com
  filtro por tipo.

{{tela:task}}

## Notificações

O sino, em todas as páginas, mostra o que está rodando agora e avisa quando uma tarefa pausa
ou termina. A notificação leva à tarefa e fica até ser lida.

{{tela:notifications}}

## Auditoria de cada execução

Cada execução do agente tem uma auditoria: sessão, modelo, para onde foi o tempo (modelo,
ferramentas, espera), tokens e cache, cada ferramenta usada, as conexões MCP e as decisões
de permissão.

{{tela:audit}}

A página **Auditoria** do workspace, para administradores, registra as ações das pessoas:
quem criou, decidiu ou cancelou tarefas, mudou pipelines e projetos, e aprovou, renomeou ou
revogou runners.

## Uso: custo

Custo, execuções, tempo de agente e tokens por dia, e a divisão por origem (as tarefas e
as propostas do agente), por pipeline, por runner, por pessoa e por etapa, com o tempo médio de
espera e de gates. Dá para olhar até 90 dias e filtrar por projeto.

{{tela:usage}}

## Uso: qualidade

Custo sem qualidade não diz muito. A aba **Qualidade** acompanha os PRs entregues em
repositórios vinculados: quantos foram aceitos sem mudança, aceitos com commits de uma
pessoa ou fechados, por pipeline, e o retrabalho por etapa (as correções pedidas em review).

{{tela:quality}}

## Retenção

O conteúdo dos anexos e os eventos completos do agente ficam pelo prazo de retenção do
workspace. Passado o prazo, o anexo mantém o nome com o aviso "removido pela retenção", e o
passo a passo mantém só os metadados. O Uso mostra quanto da cota de anexos está ocupado.
