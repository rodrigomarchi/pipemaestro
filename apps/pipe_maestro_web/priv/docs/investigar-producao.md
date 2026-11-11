**A situação:** desde ontem à tarde, alguns clientes recebem erro 500 ao finalizar a
compra. Não é sempre, e ninguém reproduziu localmente.

**O pipeline:** Investigação de produção. Ele **não altera o código**: devolve as hipóteses,
a causa mais provável e a correção proposta.

## O pedido

Conte o que se sabe: quando começou, quem é afetado, mensagens de erro, o que mudou.

> **500 no checkout desde ontem**
>
> Desde ontem 15h, cerca de 2% dos checkouts dão 500. Só cartão de crédito. O deploy de
> ontem 14h30 mudou o cliente do gateway de pagamento.

## As etapas

1. **Hipóteses**: lê o código envolvido e, se houver ferramentas de observabilidade
   conectadas, consulta logs e métricas do período. Lista as hipóteses com as evidências a
   favor e contra cada uma.
2. **Conclusão**: a causa mais provável, o impacto, a correção proposta (sem aplicar) e como
   confirmar em produção. Se as evidências não bastam, a etapa para dizendo o que falta
   medir.

## Dando acesso aos logs

O agente consulta logs e métricas por servidores MCP configurados no pipeline. Os tokens
desses servidores ficam em **Segredos**: cifrados na plataforma, entregues ao runner só
durante a execução e citados na configuração como `${NOME}`. O valor nunca aparece de
volta na tela.

## E depois

A conclusão vira o pedido de uma tarefa de [Correção de bug](/docs/corrigir-um-bug), que
escreve primeiro o teste que reproduz o problema. Assim a correção chega com a prova.
