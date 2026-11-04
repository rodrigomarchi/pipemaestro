# Entrega: A plataforma impõe tetos de custo que ninguém pediu.

## Branch
`cp/a-plataforma-impoe-tetos-de-custo-que-ni-cbf9f32c`

Confirmada como branch da tarefa (não é `main`). Árvore limpa antes desta etapa.

## Atualização com `origin/main`
`git fetch origin` feito. `origin/main` não tem commits fora da branch (`HEAD..origin/main` vazio), então não houve merge e não foi preciso repetir o `make ci`.

## Commits (`origin/main..HEAD`, do mais antigo ao mais recente)
1. `0ac3e55` Entendimento e plano: A plataforma impõe tetos de custo que ninguém pediu.
2. `89ddb73` Testes que falham: A plataforma impõe tetos de custo que ninguém pediu.
3. `5450d07` Propostas sem teto de custo; melhoria mantém o teto do pipeline
4. `2c29c63` Formulário e lista de pipelines dizem que vazio é sem limite de custo
5. `771e025` ADR 0028: teto de custo só quando configurado
6. `75b14b6` Implementação: A plataforma impõe tetos de custo que ninguém pediu.
7. `6de47fc` Revisão de convenções: moduledoc de Stage reformatado
8. `faef7de` CI verde: A plataforma impõe tetos de custo que ninguém pediu.
9. `93db35d` Telas (e2e): verificação do formulário de pipeline
10. `f95f359` Documentação e resumo: teto de custo só quando configurado

Todas as mensagens estão em português. Os commits 1, 2, 6, 8 e 10 são de artefatos de etapa (`.control-plane/`), não de código. A diferença contra `origin/main` tem 35 arquivos, com 849 inserções e 32 remoções.

Nota: os commits 1, 2, 6, 8 e 10 começam com nomes de etapa ("Entendimento e plano:", "Testes que falham:"). Isso segue o padrão já usado pelo pipeline. Não foi reescrito histórico.

## Resumo para a revisão
A plataforma impunha tetos de custo que ninguém pediu. Cada tipo de proposta fixava um orçamento no código, e o agente propunha `max_task_cost_usd` nos pipelines. Agora um teto só existe quando a pessoa o preenche.

- **`apps/pipe_maestro`**: as propostas (tarefa, decisão, pipeline, melhoria) criam o job sem `max_budget_usd`. O agente não propõe mais teto. Se devolver um mesmo assim, `Pipelines.Yaml.without_caps/1` o descarta. A importação de YAML pela pessoa continua trazendo os tetos dela. Na melhoria, o teto atual do pipeline e o de cada etapa cuja `key` continua são recolocados no resultado (`ImproveKind`, com `Pipelines.get_pipeline/2` escopada ao workspace). Sem migração.
- **`apps/pipe_maestro_web`**: o formulário de pipeline mostra "(US$, opcional)" e "Vazio é sem limite"; a lista mostra "Sem limite de custo".
- **Protocolo e runner**: sem mudança de contrato. `max_budget_usd` já era opcional no `job:assign`, e a versão do protocolo não sobe. Runners publicados já omitem a flag quando o campo vem `nil`. Há um teste de regressão no runner.
- **Documentação**: ADR nova `docs/adr/0028-teto-de-custo-so-quando-configurado.md` (indexada em `docs/README.md`); ADRs 0011, 0021 e 0022 atualizadas; spec `docs/specs/protocolo-runner.md`; plano `docs/plano/01-visao-arquitetura.md`.

## Pontos de atenção na revisão
- **Dados existentes**: pipelines que já nasceram com teto proposto pelo agente (ex.: "Evolução do PipeMaestro", US$ 40) mantêm o teto até a pessoa apagá-lo no formulário. Não há migração.
- **Custo maior nas propostas**: é a intenção. O custo segue visível em Execuções, Propostas, Uso e auditoria.
- **Limite de tempo**: os 20 min das propostas de pipeline e de melhoria passam a ser o único limite para uma análise grande. Em bases muito grandes podem cortá-la. Fora do escopo.
- **Olhar com mais atenção**: `ImproveKind.result/2` (busca do pipeline escopada ao workspace, tolerante a pipeline apagado) e `Pipelines.Yaml.without_caps/1`.
- **Teste alterado**: em `proposals_test.exs`, o pipeline "Com teto" virou "Limitado", porque o nome ia ao prompt e disparava a checagem de "teto" sem ser um teto.

## Verificação
- `make ci` → saída `0` na etapa CI (`05-ci.md`). Nenhuma correção foi necessária depois, pois não houve merge.
- `make e2e` completo passou na etapa de Telas (`06-telas.md`).
- Conferir manualmente, antes de aprovar o PR:
  1. Pipelines: "Sem limite de custo" nos pipelines sem teto.
  2. Formulário de pipeline: rótulos "(US$, opcional)" e ajuda "Vazio é sem limite".
  3. Melhoria de um pipeline com teto: o formulário aberto pela proposta mantém o teto atual.
  4. Pedido de pipeline novo ao agente: o formulário abre com os tetos vazios.

## Publicação
Nada foi enviado ao origin nem aberto PR nesta etapa. A plataforma faz o push e marca o PR (aberto desde a primeira etapa) como pronto.
