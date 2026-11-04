# Plano — A plataforma impõe tetos de custo que ninguém pediu

Base: `origin/main` em `12f34fa` (fast-forward já em dia, sem commits alheios na branch).

## Entendimento

Hoje há dois lugares onde a plataforma decide sozinha quanto se pode gastar:

1. **Propostas do agente.** Cada `Kind` fixa `max_budget_usd` no `job/3`. O
   `PipelineKind` e o `ImproveKind` usam US$ 3 (`pipeline_kind.ex:51`, `improve_kind.ex:93`),
   e o `TaskKind` e o `DecisionKind`, US$ 2 (`task_kind.ex:71`, `decision_kind.ex:104`).
   `Proposals.request/5` põe esse valor no contexto do job (`proposals.ex:92`), e o
   runner o passa ao CLI como `--max-budget-usd` (`PipeMaestroRunner.Claude.optional/1`).
   Uma análise grande é cortada no meio.
2. **O agente propõe tetos.** `PipelineKind.pipeline_schema/0` aceita
   `max_task_cost_usd`, e o `ImproveKind` usa o mesmo schema. `Pipelines.Yaml.from_map/1`
   aceita `max_task_cost_usd` e `max_budget_usd` por etapa, mesmo que o schema da etapa
   não declare o segundo, porque o schema não tem `additionalProperties: false`.
   `Proposals.Instructions.pipeline_format/0` diz "só uma regra, uma falha ou o
   orçamento param a tarefa". Um pipeline gerado já nasce com teto, como o
   "Evolução do PipeMaestro" com US$ 40.

O que fica igual, porque já trata o vazio direito:
- `PipeMaestroProtocol.Job`: `max_budget_usd` é opcional, com padrão `nil`, e só é
  validado quando vem preenchido.
- `PipeMaestroRunner.Claude.optional/1`: com `nil`, o runner não passa a flag.
- `Tasks.over_budget/1` e `Tasks.near_budget/1` (`tasks.ex:628` e `tasks.ex:885`)
  só agem com `pipeline_context["max_cost_usd"]` binário, que
  `Pipeline.context/1` só preenche quando `max_task_cost_usd` existe.
- O job de etapa (`tasks.ex:466`) leva o `max_budget_usd` da etapa, ou `nil`.
- `Pipelines.Templates` não tem teto em nenhum template (conferido).
- Os campos `max_task_cost_usd` (pipeline) e `max_budget_usd` (etapa) já são
  opcionais, sem default (migração `20261105180000_add_task_budget_to_pipelines.exs`, `Stage`).

### O que muda para quem usa
- As propostas (tarefa, decisão, pipeline, melhoria) rodam sem teto de custo e
  não são mais cortadas por orçamento. O custo continua aparecendo em Execuções,
  Propostas, Uso e na auditoria.
- Um pipeline proposto pelo agente nasce sem teto. Uma melhoria proposta mantém
  o teto que o pipeline já tem, e o agente nem fica sabendo dele.
- Os formulários dizem que deixar o campo vazio quer dizer "sem limite".

### Critérios de aceite verificáveis
1. Cada tipo de proposta cria o job sem `max_budget_usd`: a chave fica fora do contexto,
   e o `PipeMaestroProtocol.Job` resultante tem `nil`.
2. O `pipeline_schema/0`, o `schema/0` do `PipelineKind` e o do `ImproveKind` não
   declaram `max_task_cost_usd` nem `max_budget_usd`. As instruções (`pipeline_format/0`,
   os system prompts dos tipos e o exemplo YAML) não falam em orçamento, teto, `max_task_cost_usd` nem
   `max_budget_usd`. Se o agente devolver esses campos mesmo assim, o resultado os descarta.
3. Uma proposta de melhoria devolve o `max_task_cost_usd` atual do pipeline, e o
   `max_budget_usd` atual de cada etapa cuja `key` continua no pipeline,
   qualquer que seja o valor que o agente devolveu (inclusive nenhum).
4. Pipeline e etapa sem teto não pausam nem alertam por custo.
5. Com o teto preenchido pela pessoa, pausam e alertam como hoje (testes atuais de `tasks_test.exs`).
6. O runner não passa `--max-budget-usd` quando o job não tem orçamento.
7. Os textos do formulário de pipeline deixam claro que vazio é "sem limite".
8. As ADRs 0021 e 0022 são atualizadas, e a nova ADR 0028 é escrita.
9. `make ci` e `make e2e` verdes.

## Mudanças por app

### `apps/pipe_maestro` (domínio)
- **`Proposals.Kind`**: tirar `required(:max_budget_usd) => number()` do `job_spec`.
  Não vira opcional: nenhum tipo o usa, e um tipo que um dia precisar de teto
  configurável o recebe de uma configuração da pessoa, não do código.
- **`Proposals.request/5`**: tirar `"max_budget_usd" => spec.max_budget_usd` do contexto.
  O job vai sem a chave, que o protocolo lê como `nil`.
- **`TaskKind`, `DecisionKind`, `PipelineKind`, `ImproveKind`**: tirar
  `max_budget_usd:` do `job/3`. O `timeout_ms` continua.
- **`PipelineKind.pipeline_schema/0`**: tirar a propriedade `max_task_cost_usd`. O schema
  da etapa já não tem `max_budget_usd`. Não vamos acrescentar `additionalProperties: false`,
  porque o CLI valida em modo estrito e o efeito em respostas que hoje passam é incerto.
  Quem barra é o resultado (a seguir).
- **Descartar o teto que o agente devolver**: uma função pública, por exemplo
  `Pipelines.Yaml.without_caps/1` (ou `Proposals.without_caps/1`), tira
  `"max_task_cost_usd"` dos atributos e `"max_budget_usd"` de cada etapa. Ela é aplicada
  em `PipelineKind.result/2` e em `ImproveKind.result/2` depois de `Yaml.from_map/1`.
  O `Yaml.from_map/1` em si não muda: a importação de YAML pela pessoa continua
  trazendo os tetos dela.
- **`ImproveKind`**:
  - **No prompt**: o YAML do pipeline atual vai sem os tetos
    (`%{pipeline | max_task_cost_usd: nil, stages: ...max_budget_usd: nil}` antes de
    `Yaml.to_yaml/1`), para que o agente não os discuta nem os liste em `mudancas`.
  - **No resultado**: `result/2` carrega o pipeline (`pipeline_id` vem do input do job,
    e o workspace, do `job.workspace_id`, por uma busca escopada no workspace, por exemplo
    `Pipelines.get_pipeline/2` a partir do workspace do job). Depois põe nos atributos o
    `max_task_cost_usd` atual e o `max_budget_usd` de cada etapa cuja `key` ainda existe,
    em texto como o formulário espera. Como o resultado é lido quando o formulário abre,
    vale o teto de agora: se a pessoa mudou o teto depois de pedir a melhoria, o novo valor
    é o que fica.
  - Se o pipeline tiver sido apagado, o resultado vai sem tetos, e o formulário já recusa
    (`proposal_fits?`).
- **`Proposals.Instructions.pipeline_format/0`**: "só uma regra, uma falha ou o orçamento
  param a tarefa" passa a "só uma regra ou uma falha param a tarefa". O campo `max_*` não
  aparece. O `example/0` usa o template "Nova funcionalidade", que não tem teto, e um teste
  garante isso.
- **Moduledocs** que apresentam o teto como algo sempre presente:
  - `Pipelines.Pipeline` (`pipeline.ex:11`): "`max_task_cost_usd`, quando a pessoa o
    preenche, …";
  - `Pipelines.Stage` (`stage.ex:5`, `stage.ex:15`): "o orçamento, quando configurado";
  - `Jobs.Job`: só cita o campo, sem mudança.
- **Migrações**: nenhuma. As colunas já são anuláveis e sem default. Os dados existentes
  ficam como estão, porque um teto já salvo é da pessoa, e só ela o tira (pelo formulário).
- **`Tasks`**: nenhuma mudança de código. Entram testes de "sem teto" (abaixo).

### `apps/pipe_maestro_web`
- **`PipelineLive.Form`**:
  - o campo `pipeline-max-cost` fica com o rótulo "Teto de custo por tarefa (US$, opcional)"
    e a ajuda "Vazio é sem limite. Com um valor, a tarefa para e pede uma decisão ao passar
    dele.";
  - o campo `stage-budget-N` fica com o rótulo "Teto de custo (US$, opcional)" e a ajuda
    "Vazio é sem limite." (`help_text` já existe em `icon_field`, `form_components.ex:108`);
  - a descrição da seção "Execução" passa de "Quanto uma tarefa pode gastar…" para
    "Um teto de custo, se quiser, e o que vira do código.".
  - Não muda lógica: `proposal_params/1` já recebe os atributos prontos do domínio.
- **`PipelineLive.Index`**: `budget_label(nil)` passa de "Sem teto" para "Sem limite de
  custo", alinhado ao formulário. O `pipeline_live_test.exs:291` acompanha.
- **`TaskLive.Show`**: já só mostra "de US$ X" com teto. Sem mudança.
- **`BoardLive` e `DecisionsLive`**: o texto "estourar o orçamento" no estado vazio continua
  certo (só acontece com teto configurado). Sem mudança.
- **Channels**: sem mudança. O contexto do job sem a chave já vira `nil` no fio.

### `apps/pipe_maestro_protocol`
**Não muda.** `max_budget_usd` já é opcional (`job.ex:96`, `job.ex:284`).

### `apps/pipe_maestro_runner`
**Não muda no código.** `Claude.optional/1` já omite a flag com `nil`. Entra um teste em
`job_runner_test.exs` (perto do "argv adds the stage's schema, model and budget",
linha 692): um job sem `max_budget_usd` não tem `--max-budget-usd` no argv.

## Fronteiras
Nada cruza fronteira. As mudanças ficam no domínio (`Proposals`, `Pipelines`) e em textos
de LiveView. O runner só ganha um teste e continua dependendo só de `protocol`. O domínio
não passa a usar nada da web.

## Protocolo
**Não toca `apps/pipe_maestro_protocol` nem o formato dos Channels.** `max_budget_usd`
continua um campo opcional do `job:assign`. A versão do protocolo não sobe.
**Runners antigos** são compatíveis: todo runner já publicado omite a flag quando o campo
falta, porque o `nil` sempre existiu (jobs de etapa sem orçamento). Em
`docs/specs/protocolo-runner.md`, a linha 241 ganha só um esclarecimento: "`max_budget_usd`
só vem quando a pessoa configurou um teto na etapa; sem ele, o runner não passa a flag".

## Telas
- Muda o **formulário de pipeline** (rótulos e ajudas dos dois campos de teto, e a
  descrição da seção). Muda também o **texto "Sem limite de custo"** na lista de pipelines.
- Não entram `data-testid` novos. `pipeline-max-cost` e `stage-budget-N` continuam.
- Componentes: o `icon_field` atual (wrapper do Petal `field`) com `help_text`, conferido em
  `docs/guias/ui-petal.md`. Não entra markup novo.
- **Specs Playwright**: `pipeline-proposal.spec.ts`, `agent-proposals.spec.ts` e
  `task-pipeline.spec.ts` continuam verdes. Nenhum deles hoje confere os textos de teto.
  Para o critério do formulário, entra uma asserção em `pipeline-proposal.spec.ts`: o
  formulário aberto pela proposta mostra `pipeline-max-cost` vazio. Depois, rodar
  `make e2e.shots` e conferir as screenshots do formulário de pipeline e da lista, claro
  e escuro.

## Testes (ExUnit)
`apps/pipe_maestro/test/pipe_maestro/proposals_test.exs`:
- critério 1: para cada `Proposals.kinds()`, `request/5` cria o job sem a chave
  `"max_budget_usd"` no contexto, e o job no fio tem `max_budget_usd: nil`;
- critério 2, schemas: em "the schemas", `PipelineKind.pipeline_schema()` e o `schema()`
  do `ImproveKind` não têm `max_task_cost_usd` em `properties` nem `max_budget_usd` no item
  da etapa;
- critério 2, instruções: o `system_prompt` e o `prompt` do job de pipeline e de melhoria
  não contêm `orçamento`, `max_task_cost_usd` nem `max_budget_usd`. O prompt de melhoria é
  testado com um pipeline que tem teto, e o YAML mostrado ao agente não pode trazê-lo;
- critério 2, resposta: um `structured_output` de pipeline com `max_task_cost_usd: 40` e
  `max_budget_usd` numa etapa dá um `result.pipeline` sem nenhum dos dois;
- critério 3: num pipeline com `max_task_cost_usd: "40"` e uma etapa `plano` com
  `max_budget_usd: "1.5"`, uma melhoria cujo agente devolve `max_task_cost_usd: 5`, sem
  orçamento na etapa `plano` e com uma etapa nova, resulta em `"40"`, `"1.5"` em `plano` e
  nada na etapa nova. Num pipeline sem teto, a melhoria sai sem teto.

`apps/pipe_maestro/test/pipe_maestro/tasks_test.exs` (describe "the task's budget"):
- critério 4: um pipeline sem `max_task_cost_usd` cuja tarefa já gastou muito segue para a
  próxima etapa (sem `await`) e não aparece em `Tasks.alerts/2` como `:near_budget`. O job
  de uma etapa sem `max_budget_usd` vai com `nil`;
- critério 5: os testes atuais (linhas 737 e 815) continuam valendo.

`apps/pipe_maestro_runner/test/pipe_maestro_runner/job_runner_test.exs`: critério 6.

`apps/pipe_maestro_web/test/pipe_maestro_web/live/pipeline_live_test.exs`:
- os textos "sem limite" no formulário e "Sem limite de custo" na lista;
- o formulário aberto com `?proposta=` de uma melhoria mostra o teto atual do pipeline.

## Documentação
- **Nova ADR `docs/adr/0028-teto-de-custo-so-quando-configurado.md`**, curta: teto de custo
  só existe quando o usuário configura, nos dois campos (pipeline e etapa). A plataforma e o
  agente nunca propõem nem impõem teto. Uma melhoria preserva o teto atual. O custo continua
  visível. Os limites de tempo ficam, porque protegem contra processo travado. Entra o
  índice correspondente em `docs/README.md`.
- **ADR 0021**: "teto de US$ 3 e 20 minutos" passa a "limite de 20 minutos, sem teto de
  custo (ADR 0028)".
- **ADR 0022**: "com teto de custo e de tempo por tipo" passa a "com limite de tempo por
  tipo, sem teto de custo (ADR 0028)".
- **ADR 0011** (orçamento por tarefa): uma nota de que o teto é opcional e vazio por padrão
  (ADR 0028). O texto já diz "pode ter", então a mudança é mínima.
- **`docs/specs/protocolo-runner.md`**: o esclarecimento da linha 241.
- **`docs/plano/01-visao-arquitetura.md` §4.9 e tabela (linha 145)**: "aplica tetos por
  tenant/pipeline" passa a "aplica os tetos que o tenant configurou", para não sugerir teto
  imposto.

## Limites de tempo (fora do escopo, conforme pedido)
`timeout_ms` das propostas (15 min para tarefa e decisão, 20 min para pipeline e melhoria)
e `timeout_minutes` das etapas ficam. Uma observação: os 20 min das propostas de pipeline e
de melhoria são o único limite que sobra para uma análise grande, e numa base muito grande
podem cortá-la, como o teto cortava. Na prática, o efeito parece mais de teto de "tamanho de
análise" do que de processo travado. Fica registrado, sem mudar nada.

## Riscos
- **Dados existentes**: pipelines que já nasceram com teto proposto pelo agente (o
  "Evolução do PipeMaestro", US$ 40) continuam com ele, por decisão da tarefa ("só muda
  pelas mãos da pessoa"). Não há migração de dados. A entrega deve avisar que a pessoa
  apaga o valor no formulário. Os jobs de proposta já gravados guardam o
  `max_budget_usd` antigo no contexto, como histórico, sem efeito.
- **Busca do pipeline em `ImproveKind.result/2`**: o callback recebe só o job. A busca tem
  que ser escopada ao `workspace_id` do job, nunca só ao `pipeline_id`, e sobreviver a um
  pipeline apagado (devolver sem tetos em vez de levantar exceção).
- **Gasto real das propostas**: sem teto, uma proposta pode custar mais. É a intenção, e o
  custo continua visível em Execuções, Uso e Propostas.
- **Dialyzer**: tirar a chave obrigatória do `job_spec` exige tirá-la de todos os quatro
  tipos no mesmo commit.
- **Cobertura**: só entram testes. A cobertura não cai.
- **Concorrência**: nada novo.
