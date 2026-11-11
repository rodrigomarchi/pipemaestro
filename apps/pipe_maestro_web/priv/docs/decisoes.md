O agente trabalha sozinho, com todas as permissões, e só chama uma pessoa quando precisa.
Quando isso acontece, a tarefa **pausa** em "Aguardando decisão" e nada segue até alguém
decidir.

## Por que uma tarefa para

- **O agente bloqueou a etapa**: falta uma informação que muda a solução. Ele faz as
  perguntas, cada uma com as alternativas e a recomendada primeiro.
- **A etapa esgotou as tentativas**: os gates continuaram falhando.
- **Uma regra da etapa disparou**: a saída estruturada disse algo que pede uma pessoa (um
  risco alto, por exemplo).
- **O teto de custo** da tarefa foi ultrapassado.
- **Alguém interrompeu** uma etapa em execução.

Numa pausa por falha, com **Analisar falhas com IA** ligado no pipeline, o agente analisa o
que deu errado antes de você chegar e traz o diagnóstico e as perguntas.

## O questionário

{{tela:decision}}

Cada pergunta mostra as opções como cartões, com a recomendada marcada. Algumas aceitam mais
de uma opção, e todas têm "Outro" para escrever a sua. Você revisa as respostas e confirma.
Elas entram no contexto das etapas seguintes.

## As formas de decidir

| Decisão | O que acontece |
|---|---|
| Responder às perguntas | a etapa refaz com as respostas |
| Refazer | a etapa roda de novo, com as instruções que você escrever |
| Refazer a partir daqui | volta para uma etapa anterior e refaz dali em diante |
| Seguir para a próxima | aceita a etapa como está e segue |
| Cancelar a tarefa | encerra a tarefa (um membro cancela as próprias; um administrador, qualquer uma) |

**Sugerir com IA** pede ao agente uma sugestão de decisão (por exemplo, refazer com uma
instrução específica), que você aplica ou descarta.

## Onde decidir

- Na **página da tarefa**: um aviso sobre o pipeline leva à etapa que espera.
- Em **Decisões**, que junta todas as tarefas paradas do workspace; o menu mostra quantas.
- Pelo **sino**: uma pausa acende o contador e mostra um aviso, em qualquer página.
- Na **issue ou no PR**, quando a tarefa veio do GitHub ou do Forgejo:
  `/pipemaestro responder`, `/pipemaestro seguir` ou `/pipemaestro refazer`. Veja
  [Comandos](/docs/comandos).

## Depois de concluída

Uma tarefa concluída ainda aceita pedidos: escreva em **Mensagem para a tarefa** e a
correção roda como uma nova etapa, no mesmo worktree (refeito, se você o tinha removido).
