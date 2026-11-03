# 0007 — Visualização da tarefa: Markdown, diff local, linha do tempo, board e decisões

- **Status:** aceita
- **Data:** 03/11/2026
- **Roadmap:** Marco 2, itens 1, 2, 3, 6 e 7, de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)

## Contexto

Com tarefas rodando de ponta a ponta (ADRs 0005 e 0006), o resultado ainda era
difícil de ler:

- os artefatos apareciam como texto cru;
- não havia como ver o que cada etapa mudou no código;
- a linha do tempo mostrava cada ferramenta do mesmo jeito;
- o board e a lista de decisões eram dados de exemplo.

## Decisões

1. **Markdown renderizado no servidor com `mdex`** (questão em aberto 4 do roadmap). É
   a mesma escolha opcional do Petal e não exige JavaScript. O texto vem de agentes,
   então não é confiável: o HTML cru é descartado e destinos de link inseguros são
   esvaziados (modo seguro do comrak). Os artefatos podem ser alternados para texto.
   Fica de fora o destaque de sintaxe: o tema embutido usa cores fixas que não
   acompanham o modo escuro.
2. **O que cada etapa mudou, medido pelo runner com git, sem GitHub.** O runner grava
   a *tree* dos arquivos do worktree em três momentos: na criação do worktree, no
   início e no fim de cada etapa.
   - A gravação usa um índice temporário, então o que o agente coloca no stage ou
     commita não altera a medida.
   - Ficam de fora os arquivos ignorados e os diretórios clonados pelo setup.
   - O `job:finished` leva os arquivos da etapa, o patch (até 200 KB) e os arquivos da
     tarefa inteira.
   - Um diretório sem git não tem essa medida, por enquanto.
3. **Linha do tempo por ferramenta.** O protocolo passa a levar, para as ferramentas
   conhecidas, os argumentos que importam (`input`, com textos de até 4 KB) e o id que
   liga cada resultado à sua chamada. A tela mostra:
   - o comando do Bash;
   - o Edit como diff;
   - o Write com o conteúdo recolhido;
   - a lista do TodoWrite;
   - as saídas recolhidas com o número de linhas, abertas quando são erro;
   - o texto do agente em Markdown.

   O agrupamento de chamadas e os filtros ficam para depois.
4. **Board por estado, não por etapa.** As tarefas usam pipelines diferentes, então as
   colunas são os estados: em execução, aguardando decisão, concluídas e
   falharam/canceladas. Há filtros por pipeline, runner, diretório e pessoa, os
   números dos últimos 7 dias e a atividade recente.
5. **Decisões num só lugar.** Uma página lista tudo o que espera alguém e permite
   decidir ali. O contador do menu fica ao vivo em todas as páginas do workspace, por
   um hook de `on_mount` que assina o tópico `{:decisions, workspace_id}`.

## Consequências

- O mock do board (`Demo`) sai do código.
- O runner faz duas gravações de tree por etapa; num repositório grande sem
  `.gitignore` adequado isso pesa. Os diretórios do setup já ficam de fora.
