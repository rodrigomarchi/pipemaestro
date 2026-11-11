Dois pipelines que não criam funcionalidade, mas deixam o código melhor: uma revisão que só
lê e uma refatoração que não muda comportamento.

## Revisar um branch antes do PR

**A situação:** você terminou uma mudança grande e quer um segundo olhar antes de pedir
review ao time.

**O pipeline:** Revisão de código. Uma etapa só, que **não altera nada**: revisa o que está
no branch atual e ainda não está no principal, e o que não foi commitado.

> **Revisar o novo fluxo de reembolso**
>
> Foco em concorrência: dois reembolsos do mesmo pedido ao mesmo tempo.

O artefato lista os problemas por severidade (bloqueia, deveria mudar, sugestão), cada um
com arquivo, linha e o porquê.

## Refatorar com a suíte verde

**A situação:** o módulo de frete cresceu para 900 linhas e cada mudança quebra algo.

**O pipeline:** Refatoração.

> **Separar o cálculo de frete por transportadora**
>
> Hoje tudo está em `Frete.calcular/2`. Cada transportadora no seu módulo, mesma API
> pública.

| Etapa | O que faz |
|---|---|
| Mapa | quem chama o código, o que os testes cobrem e o que não cobrem, e os passos, cada um pequeno |
| Refatoração | executa os passos sem mudar comportamento; se falta teste para algo que vai mudar de lugar, escreve antes; roda a suíte a cada passo |
| Verificação | compara o diff com o mapa, procura mudanças de semântica escondidas e roda a suíte |

## Dica: o pipeline do seu time

Copie um pipeline pronto e ajuste os prompts às convenções do time, ou peça ao agente:
**Melhorar pipeline com IA** lê como as tarefas daquele pipeline foram e propõe a próxima
versão. Veja [O agente como ajudante](/docs/agente-ajudante).
