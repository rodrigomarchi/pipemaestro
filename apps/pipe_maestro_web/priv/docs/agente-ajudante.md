Além de executar as etapas, o agente ajuda a montar o trabalho. Cada ajuda gera uma
**proposta**, que você revisa antes de virar algo de verdade. Todas ficam em **Propostas**.

## Escrever a tarefa

Em **Tarefas**, **Escrever com IA** transforma uma ideia em poucas frases numa tarefa
completa: título, pedido e critérios de aceite. Você escolhe o projeto e, se quiser, o
pipeline e uma issue do GitHub como ponto de partida.

- Com **aprovação automática** (o padrão), a tarefa é criada e começa.
- Sem ela, o formulário abre preenchido para você ajustar.
- Se o agente acha que a ideia ainda não está pronta, ele não cria a tarefa: diz por quê e
  faz as perguntas. **Responder e reescrever a tarefa** pede uma nova rodada com as respostas.

É o mesmo agente da triagem das issues do GitHub e do Forgejo.

## Propor o projeto

No formulário de um projeto novo, **Analisar com IA** pede ao agente que estude um diretório do
runner, numa cópia descartável que não toca o original. A proposta volta com o nome, os
comandos de setup, teste e lint que ele conferiu, os arquivos a copiar e as notas para os
agentes. Nada é salvo até você salvar.

## Propor o pipeline

Em **Pipelines**, **Gerar com IA** pede ao agente um pipeline: você diz o que ele deve fazer e
escolhe o projeto, e o agente estuda o código numa cópia descartável. A proposta traz o que
ele entendeu, os comandos que checou e as etapas. Salvar a proposta abre o formulário do pipeline preenchido. Um teto
de custo que o agente sugira nunca vai para o formulário: tetos são decisão de uma pessoa.

## Melhorar um pipeline

**Melhorar pipeline com IA** lê como as tarefas de um pipeline foram (onde pararam, o que
falhou, o que foi refeito) e propõe a próxima versão, com as notas do porquê de cada mudança.
Aceita, ela vira a nova versão do pipeline.

## Sugerir uma decisão

Numa tarefa parada, **Sugerir com IA** traz uma decisão sugerida, por exemplo refazer a etapa
com uma instrução específica. Aplicar a sugestão segue o caminho de uma decisão comum.

## Quanto custa

Cada proposta roda o agente no seu runner e entra no Uso, na origem dela, como qualquer
execução.
