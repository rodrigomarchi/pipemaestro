Numa issue (ou no PR) de uma tarefa, quem tem permissão de escrita no repositório conduz a
tarefa por comentários. A primeira linha que começa com `/pipemaestro` é a lida.

## Os comandos

| Comando | Quando vale | O que faz |
|---|---|---|
| `/pipemaestro seguir [instruções]` | aguardando decisão | segue para a próxima etapa |
| `/pipemaestro refazer [instruções]` | aguardando decisão | nova tentativa da etapa, com as instruções |
| `/pipemaestro responder` e as respostas numeradas | com perguntas do agente | responde às perguntas, na ordem |
| `/pipemaestro pausar` | executando | pausa depois da etapa atual |
| `/pipemaestro cancelar` | ativa | cancela a tarefa |
| `/pipemaestro corrigir <pedido>` | concluída ou cancelada | nova etapa "Correção" com o pedido |

Um comando aplicado ganha uma reação 👍 e fica registrado na decisão, com quem decidiu e de
onde. Um comando que não vale para o estado da tarefa recebe uma resposta com os comandos
que valem.

## Respondendo às perguntas

As perguntas do agente chegam na issue numeradas, com as opções e a recomendada marcada.
Responda na mesma ordem:

```text
/pipemaestro responder
1. Ponto e vírgula, como o banco exporta
2. Só quem é do financeiro
```

## Exemplos

```text
/pipemaestro refazer o teste precisa cobrir o cupom de 100% também
```

```text
/pipemaestro corrigir o nome da coluna deve ser valor_total, não total
```

## O PR também conversa

- **Review pedindo mudanças**, de quem tem escrita, numa tarefa concluída: vira uma etapa
  "Correção" com o texto do review e os comentários de linha.
- **Refazer etapa** no check run do GitHub: nova tentativa daquela etapa.
- **PR integrado ou fechado**: o status na issue diz "integrado", e o desfecho entra na aba
  Qualidade do Uso.

## Merge automático

Com **Fazer o merge do PR sozinha** ligado no pipeline, depois da última etapa a plataforma:

1. espera o PR ficar pronto, com os checks do repositório terminados;
2. faz o merge do jeito escolhido (merge, squash ou rebase) quando tudo passa;
3. transforma um check vermelho ou um conflito numa etapa de correção, até o limite do
   pipeline (padrão 3);
4. para e avisa quem cuida da tarefa se o host recusar, o PR for fechado ou a espera passar
   de 6 horas. **Tentar o merge de novo**, na página da tarefa, retoma.

Os checks da própria plataforma (`pipemaestro/*`) não contam: só o CI do seu repositório.
