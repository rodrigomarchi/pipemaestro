# Documentação e resumo para a revisão

## Documentação
- **ADR nova:** `docs/adr/0028-teto-de-custo-so-quando-configurado.md`, indexada em `docs/README.md`.
- **ADRs atualizadas:** 0011 (o teto é opcional, vazio por padrão), 0021 e 0022 (sem teto de custo nas propostas, só limite de tempo).
- **Spec:** `docs/specs/protocolo-runner.md` (`max_budget_usd` só vem quando a pessoa configurou o teto).
- **Plano:** `docs/plano/01-visao-arquitetura.md` (a plataforma aplica os tetos que o tenant configurou).
- **Guias e `e2e/README.md`:** sem mudança. Não entrou componente nem `data-testid` novo.

## O que mudou e por quê
A plataforma impunha tetos de custo que ninguém pediu. Cada tipo de proposta fixava um orçamento no código, e o agente propunha `max_task_cost_usd` nos pipelines. Agora um teto só existe quando a pessoa o preenche.

### `apps/pipe_maestro`
- As propostas (tarefa, decisão, pipeline, melhoria) criam o job sem `max_budget_usd`. O `job_spec` de `Proposals.Kind` não tem mais o campo.
- O schema e as instruções de pipeline não falam em teto. Se o agente devolver um mesmo assim, `Pipelines.Yaml.without_caps/1` o descarta. A importação de YAML pela pessoa continua trazendo os tetos dela.
- A melhoria (`ImproveKind`) mostra o YAML ao agente sem tetos e recoloca no resultado o teto atual do pipeline e o de cada etapa cuja `key` continua. Para isso há `Pipelines.get_pipeline/2`, escopada ao workspace do job.
- `Tasks`: sem mudança de código. Sem migração.

### `apps/pipe_maestro_web`
- O formulário de pipeline diz "(US$, opcional)" e "Vazio é sem limite" nos dois campos de teto.
- A lista de pipelines mostra "Sem limite de custo".

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`
Sem mudança de código. Entrou só um teste de regressão no runner (sem `--max-budget-usd` quando o job não tem orçamento).

## Protocolo
**Não mudou.** `max_budget_usd` já era opcional no `job:assign`, e a versão do protocolo não sobe. **Runners antigos** continuam compatíveis: todo runner publicado omite a flag quando o campo vem `nil`, como já acontecia com etapas sem orçamento.

## Riscos e onde olhar
- **Dados existentes:** pipelines que já nasceram com teto proposto pelo agente (por exemplo, "Evolução do PipeMaestro", US$ 40) o mantêm até a pessoa apagá-lo no formulário. Não há migração de dados.
- **Custo maior nas propostas:** é a intenção. O custo segue visível em Execuções, Propostas, Uso e auditoria.
- **Limite de tempo:** os 20 min das propostas de pipeline e de melhoria passam a ser o único limite para uma análise grande. Em bases muito grandes podem cortá-la. Ficou fora do escopo.
- **Olhar com mais atenção:** `ImproveKind.result/2` (busca do pipeline escopada ao workspace, tolerante a pipeline apagado) e `Yaml.without_caps/1`.
- **Teste alterado na implementação:** em `proposals_test.exs`, o pipeline "Com teto" virou "Limitado". O nome ia ao prompt e disparava a checagem de "teto" sem ser um teto.

## Como verificar
- `make ci > /tmp/ci.log 2>&1; echo $?` → `0` (já executado na etapa 5).
- `make e2e FILE=tests/pipeline-proposal.spec.ts`. `make e2e` completo passou na etapa 6.
- `make e2e.shots`, conferindo `04-proposal-pipeline-form` nos temas claro e escuro.
- Manual:
  1. Abrir Pipelines e conferir "Sem limite de custo" nos pipelines sem teto.
  2. Abrir o formulário de um pipeline e conferir os rótulos "(US$, opcional)" e a ajuda "Vazio é sem limite".
  3. Pedir a melhoria de um pipeline que tenha teto. O formulário aberto pela proposta deve manter o teto atual.
  4. Pedir um pipeline novo ao agente. O formulário deve abrir com os tetos vazios.
