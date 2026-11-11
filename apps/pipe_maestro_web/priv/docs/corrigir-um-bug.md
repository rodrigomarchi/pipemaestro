**A situação:** o suporte avisa que pedidos com cupom mostram um total no checkout e outro
na fatura. O bug é pequeno, mas ninguém do time tem tempo agora.

**O pipeline:** Correção de bug, que só deixa a correção entrar depois de um teste provar o
problema.

## O pedido

Crie a tarefa como contaria o caso para alguém do time, com o que acontece e o que deveria
acontecer:

> **Corrigir arredondamento do total com cupom**
>
> Pedidos com cupom de 10% mostram R$ 189,91 no checkout e R$ 189,90 na fatura. O total
> deve bater nos dois lugares.

Quanto mais concreto o exemplo (valores, passos, a tela), menos o agente precisa
adivinhar.

## O que cada etapa faz

| Etapa | O que o agente faz | O que você recebe |
|---|---|---|
| Triagem | lê o pedido e confere se dá para seguir | um resumo, ou perguntas se faltar algo |
| Investigação | acha onde o total é calculado nos dois lugares | o caminho do código e a causa provável |
| Reprodução com teste | escreve um teste que **falha** por causa do bug | o teste, e a saída de `make test` falhando |
| Implementação | corrige até o teste passar, sem quebrar os outros | o diff e a suíte verde |
| Validação e auditoria | revisa a correção e procura o mesmo erro em outros pontos | os riscos e o que foi verificado |
| PR pronto | descreve a mudança para quem vai revisar | o PR, pronto para revisão |

Cada etapa começa com a cabeça limpa, lê os artefatos das anteriores e só passa quando os
gates (os testes e o lint do projeto) passam. Um gate falhou? A etapa tenta de novo, já
sabendo o que deu errado.

{{tela:task}}

## Quando falta informação

Se o pedido não diz algo que muda a solução ("o arredondamento deve ser para cima ou o do
banco?"), a Triagem para e pergunta, com as alternativas e a que o agente recomenda. Você
responde na plataforma (ou na issue, se a tarefa veio de uma) e a tarefa segue. Veja
[Decisões](/docs/decisoes).

## Depois do PR

- O PR tem um commit por etapa, no branch da tarefa: dá para revisar etapa por etapa.
- Achou algo na revisão? Escreva o pedido em **Mensagem para a tarefa**: ele roda como uma
  nova etapa "Correção" no mesmo worktree. Com o GitHub ou o Forgejo conectados, um review
  pedindo mudanças faz o mesmo sozinho.

## Dicas

- Bugs de produção sem causa clara rendem mais com
  [Investigação de produção](/docs/investigar-producao) antes: ela não altera nada e
  devolve a correção proposta, que vira o pedido desta tarefa.
- Escreva no `CLAUDE.md` ou no `AGENTS.md` do repositório as convenções do projeto: toda
  etapa os lê.
