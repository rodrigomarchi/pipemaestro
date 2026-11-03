# 0008 — Projetos, gates por comando, regras e retentativa com feedback

- **Status:** aceita
- **Data:** 03/11/2026
- **Roadmap:** Marco 3, itens 1 a 4, de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)

## Contexto

O motor só conferia o contrato de saída da etapa: `status`, `resumo` e o artefato. O
plano original pede gates mecânicos (a reprodução falha, a suíte passa depois da
correção). Pede também que o específico de cada projeto (como instalar, testar,
lintar) não fique repetido em cada pipeline.

## Decisões

1. **Projeto é a configuração de um diretório.**
   - Fica no workspace e é casado pelo nome do diretório em qualquer runner que o
     ofereça.
   - Guarda os comandos de setup, de teste e de lint, os caminhos a clonar para o
     worktree e notas para os agentes.
   - A tarefa grava um retrato do projeto ao começar, como faz com o pipeline.
   - O setup do retrato vai ao runner no `setup` do job (ADR 0006); sem projeto, o
     runner continua detectando os caminhos.
   - Os prompts usam `{{projeto.nome}}`, `{{projeto.setup}}`, `{{projeto.teste}}`,
     `{{projeto.lint}}` e `{{projeto.notas}}`; sem projeto, essas variáveis ficam
     vazias.
2. **Gates são comandos da etapa, rodados pelo runner, julgados pelo control plane.**
   - A etapa lista até 10 comandos, cada um devendo passar (código 0) ou falhar (`!`
     na frente). As variáveis `{{projeto.*}}` são preenchidas antes de enviar, e um
     gate que fica vazio (projeto sem o comando) é descartado.
   - O runner roda os gates no worktree depois que o agente termina bem e informa
     código, saída e se cada um foi atendido.
   - Um gate não atendido é um erro da tentativa: entra na regra de retentativas.
3. **Regras declarativas sobre a saída estruturada.**
   - O formato é `campo == valor` ou `campo != valor`, um por linha. A comparação é
     do texto do valor, então `false` casa com o booleano `false`.
   - A primeira regra que casa deixa a etapa como aprovada e pausa a tarefa para
     decisão, com a regra como motivo.
   - Regras mais ricas (desviar para outra etapa, operadores numéricos) ficam para
     quando houver necessidade.
4. **Retentativa com feedback.**
   - A tentativa que segue uma que falhou recebe no prompt uma seção própria: o erro,
     o resumo da anterior e a saída (o fim, 2 KB) dos gates não atendidos.
   - Vale para a retentativa automática e para "Refazer etapa".
   - O feedback fica gravado na tentativa e aparece na tela.

## Consequências

- O pipeline "Correção de bug" pode exigir, de forma mecânica, que o teste de
  reprodução falhe e depois passe, desde que a etapa nomeie o comando. Os templates
  continuam sem gates: o comando de teste é de cada projeto.
- O protocolo ganha `gates` no `Job` e no `job:finished`, de forma aditiva (versão 3).
