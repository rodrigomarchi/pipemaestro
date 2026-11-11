**A situação:** o financeiro pediu para exportar os pedidos do mês em CSV, para conciliar
com o banco. É uma funcionalidade pequena, mas mexe com dados sensíveis.

**O pipeline:** Nova funcionalidade, com as revisões de código e de segurança rodando ao
mesmo tempo no fim.

## O pedido

> **Exportar pedidos em CSV**
>
> O financeiro precisa baixar os pedidos do mês para conciliar com o banco.

O pedido é curto de propósito. A primeira etapa transforma o pedido numa especificação, e
é ali que aparecem as dúvidas.

## As etapas

{{tela:pipeline}}

1. **Especificação**: o que muda para quem usa, os casos de borda e os critérios de aceite.
   Se o pedido for ambíguo a ponto de mudar a solução, a etapa para e pergunta.
2. **Plano**: os arquivos a mudar, a ordem e os testes que provam cada critério. Não mexe
   no código.
3. **Implementação**: o plano, com os testes, até a suíte e o lint passarem.
4. **Revisão de código** e **Revisão de segurança**, em paralelo, no mesmo worktree: uma
   olha o diff contra a especificação, a outra só entradas, permissões, segredos e dados
   sensíveis em logs. Um problema grave em qualquer uma para a tarefa.

## As perguntas do agente

Neste caso, a Especificação parou com duas perguntas:

{{tela:decision}}

Cada pergunta traz as opções e a que o agente recomenda. Escolha, escreva em "Outro" se
nenhuma serve e confirme: a tarefa segue com as respostas no contexto de todas as etapas
seguintes.

## Ajustando o pipeline ao seu time

- **Outra revisão em paralelo** (acessibilidade, performance): insira uma etapa no mesmo
  grupo das revisões, direto no diagrama do pipeline.
- **Um modelo por etapa**: um modelo mais forte no Plano e na Revisão, um mais rápido na
  Implementação.
- **Teto de custo**: um teto por tarefa pausa a tarefa para uma decisão quando o custo
  passa dele.
- **Continuar a sessão**: uma etapa pode retomar a sessão do agente da etapa anterior em
  vez de começar do zero, útil quando a Implementação precisa do raciocínio do Plano.
