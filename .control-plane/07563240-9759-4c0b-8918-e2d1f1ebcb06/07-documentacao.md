# Documentação e resumo

## Documentação

- **ADR:** não há ADR novo. O ajuste completa uma consequência prevista no [ADR 0029](../../docs/adr/0029-questionario-de-decisao.md), que deixava "um ajuste por pipeline para desligá-la" para depois. A nota está em Consequências do próprio ADR, então o índice em `docs/README.md` não muda.
- **Spec:** `docs/specs/maquina-de-estados-tarefa.md` diz que a análise automática só ocorre com `auto_analysis` ligado (tabela de resultados, passos em paralelo e a seção "Análise automática").
- **Sem mudança:** `docs/specs/protocolo-runner.md` (o protocolo não mudou), os guias, `e2e/README.md` e `docs/plano/`. Eles não descrevem o ajuste.
- Nenhum arquivo em `apps/` foi tocado nesta etapa.

## Resumo para quem vai revisar

### O que mudou e por quê

Toda pausa por falha (tentativas esgotadas, gate reprovado, erro do CLI) e todo bloqueio sem nada a perguntar pedia ao agente uma análise, de até US$ 1. Agora cada pipeline decide isso com o ajuste `auto_analysis`, ligado por padrão.

- **`pipe_maestro`:**
  - Migração `20261124100000_add_auto_analysis_to_pipelines.exs`, em `apps/pipe_maestro/priv/repo/migrations/`, com `default: true, null: false`.
  - `Pipeline` ganha o campo e o grava no retrato da tarefa (`context/1`).
  - `Tasks.await/3` só pede a análise quando o retrato não diz `false`, então uma tarefa antiga, sem a chave, continua com a análise.
  - O YAML escreve `auto_analysis: false` só quando desligado e o aceita na importação.
  - Uma melhoria proposta pelo agente (`ImproveKind`) mantém o valor atual do pipeline.
- **`pipe_maestro_web`:**
  - O drawer do pipeline ganha o switch "Analisar falhas com IA" na aba Entrega.
  - O resumo do pipeline avisa quando a análise está desligada.
  - A tela da pausa não mudou: sem job de análise, ela já mostra só o motivo e a decisão manual (inclusive "Sugerir com IA").
- **`pipe_maestro_protocol`:** não mudou.
- **`pipe_maestro_runner`:** uma correção fora do escopo, em `gate_cache.ex`. O cache de gates copiava o índice do git com mtime novo, e um arquivo mudado no mesmo segundo do índice e com o mesmo tamanho entrava na árvore com o conteúdo antigo. Isso fazia um teste do runner falhar de forma intermitente e podia dar um gate como "já passou" sobre código velho. A cópia agora mantém o mtime do índice. O detalhe está em `03-implementacao.md`.

### Protocolo e runners antigos

Não mudou. O ajuste só decide, no control plane, se uma proposta que já existia (`analysis`) é pedida. Runners antigos seguem compatíveis: apenas deixam de receber jobs `analysis` dos pipelines com o ajuste desligado.

### Riscos e o que olhar com mais atenção

- **Migração:** `ADD COLUMN ... DEFAULT true NOT NULL`, sem backfill. Os pipelines existentes ficam ligados.
- **Tarefas antigas:** o ajuste lê o retrato da tarefa e trata chave ausente ou `nil` como ligado. É o ponto que garante que nada muda para o que já existe.
- **Retrato imutável:** editar o pipeline depois de criar a tarefa não muda essa tarefa, e há teste nos dois sentidos.
- **Correção do runner:** é a única mudança fora do tema. Vale conferir o cache de gates por isso.
- **Melhoria por IA:** `ImproveKind` agora fixa o valor atual, para um agente não religar a análise (e o gasto) nem desligá-la sem pedido.

### Como verificar

```sh
make ci                                                   # compile, format, credo, testes com cobertura, dialyzer
make e2e FILE=tests/pipeline-auto-analysis.spec.ts       # switch na aba Entrega, salvo e reaberto
make e2e                                                  # suíte inteira
```

Na tela:

1. Abra o editor de um pipeline, clique na entrada do diagrama e vá à aba "Entrega". O switch "Analisar falhas com IA" vem ligado.
2. Desligue e salve. A página do pipeline mostra "Sem análise automática de falhas".
3. Crie uma tarefa nesse pipeline e faça uma etapa falhar até esgotar as tentativas. A tarefa pausa só com o motivo e a decisão manual (Refazer, Seguir, Cancelar e "Sugerir com IA"), sem o aviso "analisando…" e sem nenhum job de proposta `analysis` em Propostas.

### Docs e artefatos

- Atualizados: `docs/adr/0029-questionario-de-decisao.md` e `docs/specs/maquina-de-estados-tarefa.md`.
- Etapas anteriores: `01-plano.md`, `02-testes.md`, `03-implementacao.md`, `04-revisao.md`, `05-ci.md` e `06-telas.md`, nesta pasta.
