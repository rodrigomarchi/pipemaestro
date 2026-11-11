**A situação:** saiu uma versão nova do framework web que vocês usam, com correções de
segurança e algumas mudanças que quebram compatibilidade. Atualizar é chato e ninguém quer
ler o changelog inteiro.

**O pipeline:** Atualização de dependência.

## O pedido

Diga a dependência e a versão alvo. Se souber de algo sensível, conte:

> **Atualizar Phoenix para 1.8**
>
> Atualizar `phoenix` de 1.7.14 para 1.8.1. Atenção aos layouts, que mudaram de lugar.

## As etapas

| Etapa | O que faz |
|---|---|
| Changelog | lê o changelog entre a versão atual e a alvo e lista o que afeta **este** projeto, com os pontos do código que usam o que mudou |
| Atualização | atualiza, ajusta o código e roda setup, testes e lint até passarem |
| Risco | resume para quem revisa: o que mudou de comportamento, o que os testes cobrem e o que vale testar à mão |

O artefato da etapa Risco é o que você lê primeiro: ele diz onde concentrar a revisão.

## Por que funciona bem

- O worktree é descartável: se a atualização não fizer sentido, remova-o e nada no seu
  diretório mudou.
- Os gates usam os comandos do projeto, então "passou" significa a suíte de vocês verde, e
  não a opinião do agente.

## Variações

- **Várias dependências pequenas**: uma tarefa por dependência. Elas rodam em paralelo,
  cada uma no próprio branch, e uma que quebre não segura as outras.
- **Rotina**: com o GitHub ou o Forgejo conectados, abra uma issue por atualização pendente e
  ponha a label `pipemaestro`: cada uma vira uma tarefa deste pipeline. Veja
  [Uma issue vira PR](/docs/issue-vira-pr).
