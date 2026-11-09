# Implementação: ajuste `auto_analysis` por pipeline

O plano (`01-plano.md`) está implementado e os testes da etapa 2 passam sem alteração, com as mesmas asserções. `make ci.quick` passou (saída 0). O spec e2e `tests/pipeline-auto-analysis.spec.ts` também passou.

## O que mudou, por app

### `apps/pipe_maestro` (domínio)

- **Migração** `priv/repo/migrations/20261124100000_add_auto_analysis_to_pipelines.exs`: `pipelines.auto_analysis boolean NOT NULL DEFAULT true`. Os pipelines existentes ficam ligados.
- **`Pipelines.Pipeline`**:
  - o campo `auto_analysis` (padrão `true`) entra no `@type t`, no `cast` e no `@moduledoc`;
  - `context/1` grava `"auto_analysis"` no retrato da tarefa.
- **`Tasks`**:
  - `await/3` só chama `request_analysis/1` quando `asking == :analysis` e `auto_analysis?(task)`;
  - `auto_analysis?/1` lê o retrato e trata `false` como desligado e qualquer outro valor (chave ausente, `nil`) como ligado, então tarefas antigas não mudam;
  - o ponto único cobre `{:exhausted, _}`, bloqueio sem perguntas e grupo sem perguntas, e um bloqueio com perguntas continua com o questionário do agente;
  - `@moduledoc` e o comentário de `await/3` foram atualizados.
- **`Pipelines.Yaml`**:
  - `to_yaml/1` escreve `auto_analysis: false` só quando desligado;
  - `from_map/1` aceita a chave;
  - `without_caps/1` mantém a chave, e o `@doc` diz por quê.
- **`Proposals.ImproveKind`**: `with_caps_of/2` mantém o `auto_analysis` atual do pipeline, como já fazia com o merge. Desligar a análise é escolha de uma pessoa.

### `apps/pipe_maestro_web`

- **`PipelineLive.FormFields`**:
  - na aba "Entrega", logo depois do teto de custo, há um `<.field type="switch">` "Analisar falhas com IA" com `help_text` e `data-testid="pipeline-auto-analysis"`;
  - `:auto_analysis` entra na lista de campos da aba em `@entry_tabs`.
- **`PipelineComponents.pipeline_summary/1`**: mostra "Sem análise automática de falhas" (`data-testid="pipeline-summary-no-analysis"`) só quando o ajuste está desligado.
- **`TaskLive.DecisionPanel` e `DecisionsLive`**: sem mudança. Com `decision_analysis_job_id: nil`, a tela já mostra só o motivo e a decisão manual, incluindo "Sugerir com IA".

### `apps/pipe_maestro_protocol`

Não muda.

### `apps/pipe_maestro_runner`

Uma correção fora da tarefa, exigida pela regra "todo erro encontrado é seu", detalhada abaixo. O protocolo não mudou.

## Correção encontrada no caminho: teste intermitente do runner

`make ci.quick` falhou na primeira vez em `PipeMaestroRunner.GatesTest` "a change to the tree runs it again, committed or not". Esse teste falhava em cerca de 20% das execuções, sem relação com esta tarefa.

- **Causa:** `GateCache.tree/3` copia o índice do git para calcular a árvore, e a cópia ganhava mtime novo. O git rehasheia entradas "racily clean", gravadas no mesmo segundo do índice, comparando o mtime delas com o do arquivo de índice. Com a cópia parecendo mais nova, um arquivo mudado naquele segundo e com o mesmo tamanho (`v1` para `v2`) entrava na árvore com o conteúdo antigo. A chave do cache ficava errada.
- **Efeito em produção:** o mesmo, mais raro. Um gate poderia ser dado como "já passou nesta árvore" sobre conteúdo velho.
- **Evidência:** um script com a sequência do teste, repetido 30 vezes, mostrava a árvore errada 2 vezes, sempre a do passo com `lib.ex` mudado.
- **Correção** (`apps/pipe_maestro_runner/lib/pipe_maestro_runner/gate_cache.ex`): `copy_index/2` copia o índice e restaura o mtime original na cópia (`File.touch/2`). Depois disso, o script deu 0 de 90 e o arquivo de teste passou em 12 de 12 execuções seguidas.
- **Teste:** nenhum novo. O teste existente cobre o caso; ele só dependia do tempo e agora passa de forma estável.

## Documentação

- `docs/adr/0029-questionario-de-decisao.md`: em Consequências, o "fica para depois" virou a descrição do ajuste (padrão ligado, retrato na tarefa, "Sugerir com IA" disponível, perguntas do agente mantidas).
- `docs/specs/maquina-de-estados-tarefa.md`:
  - "Análise automática" passa a dizer que ela só ocorre com o ajuste ligado e que um retrato sem a chave conta como ligado;
  - a pausa desligada leva só o motivo;
  - a tabela de resultados e o item de passos paralelos dizem "(se ligada)".

## Como verificar

```sh
mix test apps/pipe_maestro/test/pipe_maestro/tasks_test.exs \
         apps/pipe_maestro/test/pipe_maestro/pipelines_test.exs \
         apps/pipe_maestro/test/pipe_maestro/proposals_test.exs        # 177 passam
mix test apps/pipe_maestro_web/test/pipe_maestro_web/live/pipeline_live_test.exs \
         apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs \
         apps/pipe_maestro_web/test/pipe_maestro_web/components/pipeline_components_test.exs  # 103 passam
make e2e FILE=tests/pipeline-auto-analysis.spec.ts                      # 1 passa
make ci.quick                                                           # saída 0
```

Para ver na tela: abra o editor do pipeline, clique na entrada do diagrama e vá para a aba "Entrega". O switch "Analisar falhas com IA" vem ligado. Desligado, a página do pipeline mostra "Sem análise automática de falhas", e uma tarefa que falha pausa só com o erro e a decisão manual.

## Para a etapa Telas

Ainda faltam as capturas claro e escuro do drawer: `make e2e.shots FILE=tests/pipeline-auto-analysis.spec.ts` (shot `pipeline-auto-analysis`), copiadas para `$CP_FILES_DIR`. Falta também a suíte e2e inteira.

## Commits

- `feat: ajuste auto_analysis por pipeline para a análise automática das falhas`
- `feat(ui): switch "Analisar falhas com IA" no drawer e aviso no resumo`
- `docs: análise automática só com o ajuste do pipeline ligado`
- `fix(runner): cache de gates não esconde arquivo mudado no segundo do índice`
