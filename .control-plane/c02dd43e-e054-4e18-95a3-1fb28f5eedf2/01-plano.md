# Plano: qualidade das entregas no Uso

Base: `origin/main` em `225fdfd` (a branch não tinha commits próprios; fast-forward sem mudanças).

## Entendimento

Hoje a página **Uso** (`PipeMaestroWeb.UsageLive`, `PipeMaestro.Usage`) diz quanto o trabalho
dos agentes custou, não se ficou bom. A tarefa acrescenta a métrica prevista em
`docs/plano/01-visao-arquitetura.md` §9 (Fase 3) e `docs/plano/02-contexto-discovery.md` §6.1:

- para cada tarefa entregue em PR de um repositório ligado, um **desfecho** persistente:
  quando ficou pronta, se foi integrada, fechada ou segue aberta, quantos commits humanos o PR
  recebeu e quantas rodadas de review viraram correção;
- na tela, uma aba **Qualidade** com as taxas (aceitos sem alteração, com alteração, fechados,
  em aberto), o tempo até o merge, as rodadas de review, o retrabalho por etapa e as etapas
  que mais pausam, respeitando período, pipeline e projeto.

Critérios de aceite verificáveis (numeração da tarefa):

1. PR com um commit que o pipeline não empurrou, depois `:pr_closed` mergeado → "aceito com
   alteração" (GitHub e Forgejo simulados).
2. Review rejeitado → "Correção N" pelo pipeline → merge → "aceito com alteração", e a
   correção conta como retrabalho de origem **review** na tabela por etapa.
3. Mergeado sem commit humano e sem correção por review → "aceito sem alteração"; fechado
   sem merge → "fechado".
4. Reprocessar o mesmo webhook ou ler os commits duas vezes não muda contagens.
5. Retentativas, refazer, decisões e pausas por etapa batem com `stage_runs` e `decisions`.
6. Período, pipeline e projeto filtram a aba Qualidade.
7. Spec e2e `e2e/tests/usage-quality.spec.ts` com dados semeados; `make e2e.shots` claro e escuro.
8. ADR 0053, `docs/specs/integracoes.md` atualizado, AGENTS.md se houver contexto novo.
9. `make ci` (com Dialyzer) e `make e2e` verdes.

## Decisões de desenho (tomadas aqui, com o porquê)

### D1. Tabela própria `integration_pr_outcomes`, schema `PipeMaestro.Integrations.PrOutcome`

Uma linha por tarefa (`unique(task_id)`), e não colunas em `tasks`:

- `tasks` já é larga e é reescrita a cada mudança (`Tasks.notify/1`, `Feedback`, `AutoMerge`);
  campos cumulativos ali correm o risco de serem zerados como `merge_fixes` (`Tasks.retry_merge/2`).
- Quem escreve o desfecho são as integrações (webhook, API do host, Reconciler); quem lê é o
  `Usage`. O contexto `Integrations` já é dono de tudo que vem do host, por isso o schema
  mora lá e `Usage` só consulta (como já faz com `Tasks.Task` e `StageRun`).
- Upserts idempotentes ficam simples numa tabela pequena (`on_conflict`, arrays de SHA).

Campos:

| Campo | Tipo | Para quê |
|---|---|---|
| `task_id` | FK única, `on_delete: :delete_all` | a tarefa |
| `workspace_id`, `linked_repo_id` | FK | filtros e o Reconciler |
| `pr_number`, `pr_url` | int, string | onde ler o PR |
| `ready_at` | utc_datetime | primeira vez `succeeded` com `pr_url`; nunca reescrito |
| `state` | string `open`/`merged`/`closed` | desfecho |
| `merged_at`, `closed_at` | utc_datetime | datas do host quando vierem, senão o momento visto |
| `review_rounds` | int, default 0 | reviews rejeitados que viraram correção |
| `review_keys` | `{:array, :string}` | id do review (ou da entrega) já contado: idempotência |
| `pipeline_shas` | `{:array, :string}` | SHAs conhecidos como do pipeline |
| `human_shas` | `{:array, :string}` | SHAs humanos, sem repetição |
| `observed_head` | string | último `head_sha` do pipeline já absorvido |
| `commits_tracked` | boolean | o host deixa a plataforma ler commits (`api_mode` `control_plane`) |
| `commits_final` | boolean | a leitura depois do merge/fechamento foi feita |
| `commits_error` | string | último erro da API, para o Reconciler tentar de novo |

A classificação é **derivada** (função `PrOutcome.classify/1` e a mesma regra em SQL no
`Usage`), nunca gravada: `merged` + `human_shas == []` + `review_rounds == 0` → `:accepted_clean`;
`merged` com algum dos dois → `:accepted_changed`; `closed` → `:closed`; `open` → `:open`.

### D2. Critério de commit humano (por SHA, por posição na lista do PR)

O autor do commit não serve (o runner commita com a identidade da máquina da pessoa). Nova
callback `Provider.pr_commits/3` devolve os commits do PR em ordem (mais antigo primeiro, como
GitHub e Forgejo respondem), `%{sha, committed_at, parents}`, todas as páginas. Uma
**observação** (`PipeMaestro.Integrations.PrOutcomes.observe/2`) lê a lista `L` e:

1. Se a tarefa tem um `head_sha` novo do pipeline (≠ `observed_head`) e ele está em `L`: os
   SHAs de `L` até ele, inclusive, que não são humanos já conhecidos, entram em
   `pipeline_shas`; os que vêm **depois** dele são humanos. `observed_head` passa a ser ele.
2. Fora isso (tarefa parada, a nova etapa começando, merge, fechamento, passagem periódica):
   todo SHA de `L` que não está em `pipeline_shas` é humano.
3. Commits de merge (mais de um pai) nunca contam como humanos: "Update branch" no host
   traz a base para o branch e não é alteração do trabalho entregue.
4. Os conjuntos só crescem (união); ler duas vezes não muda nada. SHAs reescritos por
   force-push somem de `L` mas continuam contados.

Quando observar (sempre em segundo plano, nunca no caminho da tarefa):

- **depois de cada entrega** e **ao começar uma nova etapa** (correção, refazer, seguir de uma
  pausa): o `PipeMaestro.Integrations.FeedbackWorker` já recebe `{:linked_task_updated, id}` a
  cada mudança da tarefa e roda uma vez por tarefa (`Integrations.background/1`); ele passa a
  chamar `PrOutcomes.observe/2` depois de `Feedback.sync/1`, só para tarefas com desfecho
  `open`;
- **no merge e no fechamento**: `Conversation` grava o estado na hora e agenda a leitura final
  (`commits_final`);
- **periodicamente**: o `Reconciler` relê os desfechos com `commits_error` ou sem
  `commits_final`.

Limitação aceita e registrada no ADR: um commit humano empurrado *enquanto* uma etapa roda e
que o runner incorpora antes do seu push fica antes do `head_sha` e é contado como do pipeline.
Para conexões `api_mode` `runner` a plataforma não chama o host: `commits_tracked = false`, a
classificação usa só reviews e o desfecho vem dos webhooks; a aba diz quantos PRs não tiveram
commits lidos.

### D3. Origem das correções: coluna `decisions.origin`

`Decision` com `action: :correct` não diz quem pediu (`decided_via` é igual para comando em
comentário e para review). Nova coluna `origin` (`Ecto.Enum`: `:person`, `:review`,
`:auto_merge`, nula nas decisões que não são correção). `Tasks.correct/3` ganha a opção
`:origin` (default `:person`); `Conversation.correct_from_review/4` passa `:review`,
`AutoMerge` passa `:auto_merge`. A migração preenche `:auto_merge` onde `decided_via =
'merge automático'` e `:person` nas outras correções antigas (reviews antigos não são
distinguíveis; fica dito no ADR).

### D4. Pausas sem tabela nova

Cada pausa (`awaiting_decision`) termina numa `Decision` `:retry`/`:advance`/`:cancel` com o
`stage_index` da pausa (`Tasks.decide/5`, `Tasks.cancel_task/2`), ou ainda está aberta. Pausas
por etapa = decisões não-`:correct` na etapa + tarefas em `awaiting_decision` nela. É o que o
critério 5 pede ("bate com `stage_runs` e `decisions`"). Uma pausa encerrada por `redo_from/4`
sem decisão fica de fora; o ADR registra.

### D5. Período e agrupamentos

- Desfechos: período pelo `ready_at` (a tarefa pede). Pipeline por `tasks.pipeline_name`,
  projeto por `tasks.project_id`.
- Retrabalho por etapa e pausas: período pela data do evento (`stage_runs.inserted_at`,
  `decisions.inserted_at`), porque valem para toda tarefa, entregue em PR ou não.
- Etapas por `(pipeline_name, key)`, com as etapas `correcao-N` agrupadas numa linha
  "Correções" (chave `correcao`), que leva as colunas por origem.
- Taxa ao longo do tempo **por semana** (`date_trunc('week', ready_at)`): com poucos PRs por
  dia, a taxa diária oscila entre 0 e 100% e não diz nada; com o filtro de 7 dias são 1–2 pontos.
- Tempo até o merge: **mediana** (`percentile_cont(0.5)`), menos sensível a um PR esquecido.

### D6. Filtro de projeto na barra do Uso

A barra de `UsageLive` hoje só tem pipeline e período, embora `Usage.report/3` e
`Insights.jobs_query/3` aceitem `"project_id"`. O critério 6 pede projeto: entra um select de
projeto (`Projects.list_projects/1`) na barra, valendo para todas as abas.

## Mudanças por app

### `apps/pipe_maestro` (domínio)

Migrações (`priv/repo/migrations/`):

- `create_integration_pr_outcomes`: a tabela de D1, índices em `task_id` (único),
  `(workspace_id, ready_at)` e `(state)` parcial para `open`.
- `add_origin_to_decisions`: coluna `origin` (string) + preenchimento de D3.
- Preenchimento opcional de tarefas antigas: **não** na migração. Um
  `PrOutcomes.backfill/1` idempotente (tarefas `succeeded` com `pr_url` e `linked_repo_id`,
  `ready_at` = o `inserted_at` da primeira `StageRun` passada da última etapa original) só se
  sobrar tempo; fica fora dos critérios.

Módulos:

- `PipeMaestro.Integrations.PrOutcome` (schema, `classify/1`).
- `PipeMaestro.Integrations.PrOutcomes` (novo, funções públicas com `@spec`):
  - `ready(task)`: upsert com `on_conflict: :nothing` quando a tarefa está `succeeded`, tem
    `pr_url` e `linked_repo_id`; `ready_at = task.finished_at`. Chamada em `Tasks.finish/2`
    (`:succeeded`) e em `Feedback.write_pr/5` (o PR do modo `control_plane` pode nascer
    depois do `finish`).
  - `merged(task, at)`, `closed(task, at)`: só mudam um desfecho `open`; não reescrevem datas.
  - `review_round(task, key)`: incrementa se `key` não está em `review_keys` (um `UPDATE …
    WHERE NOT (key = ANY(review_keys))`, atômico).
  - `observe(task_id, moment)`: D2; erros da API vão para `commits_error`, nunca levantam.
  - `pending_ids/0`: desfechos `open` ou sem `commits_final` / com `commits_error`, para o
    Reconciler.
- `PipeMaestro.Integrations.Provider`: callback `pr_commits(client, repo, number) ::
  {:ok, [%{sha, committed_at, parents}]} | error()`; `get_pr/3` passa a trazer `merged_at` e
  `closed_at`.
- `PipeMaestro.Integrations.GitHub`: `GET /repos/:r/pulls/:n/commits` com `all_pages/3`
  (o GitHub limita a lista a 250 commits; o ADR registra); `pull/1` com `merged_at`/`closed_at`.
- `PipeMaestro.Integrations.Forgejo`: `GET /repos/:r/pulls/:n/commits` com `all_pages/4`
  (`x-total-count`); `pull/1` idem.
- `PipeMaestro.Integrations.Event`: `pr` passa a `%{number, merged, head, merged_at,
  closed_at}` (lidos do payload de GitHub e Forgejo quando vierem); `review` ganha `id` no
  Forgejo se o payload trouxer (o GitHub já traz).
- `PipeMaestro.Integrations.Conversation.handle/3`:
  - `:pr_closed` mergeado: além de `issue_feedback["merged"]`, `PrOutcomes.merged/2` e leitura
    final dos commits em segundo plano;
  - `:pr_closed` sem merge: `PrOutcomes.closed/2` e `{:processed, "pull request fechado sem
    integrar", …}` quando há tarefa (sem tarefa continua `:continue`/ignorado; nada mais dispara);
  - `correct_from_review/4`: se o review (`review.id`, senão o `external_id` da entrega) já foi
    contado, `{:ignored, "review já aplicado"}` — isso também impede uma segunda correção ao
    reprocessar a entrega; com a correção feita, `PrOutcomes.review_round/2` e `origin: :review`.
- `PipeMaestro.Integrations.AutoMerge.merged/1` e `correct`: `PrOutcomes.merged/2`;
  `origin: :auto_merge`.
- `PipeMaestro.Integrations.FeedbackWorker`: `observe/2` depois do `sync`.
- `PipeMaestro.Integrations.Reconciler.run/2`: novo passo `outcomes` — para cada desfecho
  pendente de conexão `control_plane`, `get_pr/3` (pega merge/fechamento que o webhook perdeu,
  com as datas do host) e `observe/2`; `guarded/2` como os outros passos; conta no mapa de
  retorno (`outcomes:`).
- `PipeMaestro.Tasks`: `finish/2` chama `PrOutcomes.ready/1`; `correct/3` aceita `:origin`.
  `Tasks.Decision` ganha o campo `origin`.
- `PipeMaestro.Usage.quality(workspace, since, filters \\ %{})`, `@spec` e tipo `quality()`:
  - `total` e `by_pipeline`: `delivered`, `accepted_clean`, `accepted_changed`, `closed`, `open`
    (contagens e percentuais sobre os decididos e sobre o total — a tela mostra % do total),
    `median_merge_ms`, `review_rounds_per_pr`, `untracked` (sem leitura de commits);
  - `by_stage`: `pipeline`, `stage`, `name`, `retries` (runs com `attempt > 1`), `redone`
    (decisões `:retry` + soma de `requeue`), `decisions`, `pauses`, `review_fixes`,
    `merge_fixes`, `person_fixes`;
  - `top_pauses`: etapas por pausas, decrescente, até 10;
  - `by_week`: `week`, `delivered`, `accepted_clean`, taxa.
  - Filtros como `report/3` (`"pipeline"`, `"project_id"` com `Ecto.UUID.cast`).

### `apps/pipe_maestro_web`

- `PipeMaestroWeb.UsageLive`: aba `{"qualidade", "Qualidade", "hero-check-badge"}` no fim de
  `@tabs`; `load/1` chama `Usage.quality/3`; select de projeto na barra (D6). Nenhuma regra no
  LiveView: só formatação (percentual, duração com `format_duration/1`).
- Componente de função local (ou em `PipeMaestroWeb.UsageComponents` se ficar grande) para a
  tabela de qualidade, reaproveitando `usage_table`/`card` (ADR 0052) e `.table` do Petal.
- **Channels: não mudam.**

### `apps/pipe_maestro_protocol` — **não muda**

### `apps/pipe_maestro_runner` — **não muda**

## Fronteiras

- Tudo novo no domínio fica em `Integrations` e `Usage`; o domínio continua sem web.
- O runner não ganha dependência; nada em `protocol`.
- `Usage` lê `PrOutcome` como já lê `Tasks.Task`/`StageRun` (consultas Ecto, mesmo app).

## Protocolo

Não toca `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels. O
`head_sha` continua vindo do `job.delivery["commit"]` que o runner já manda
(`Tasks.maybe_record_pr/2`). `docs/specs/protocolo-runner.md` não muda, a versão não sobe, e
runners antigos seguem iguais (compatíveis).

## Telas

`UsageLive`, `?aba=qualidade`, abaixo das abas (nada ao lado):

- Linha de 4 cartões (`.card variant="outline"` + `.card_content`, como os totais da Visão
  geral): aceitos sem alteração (%), com alteração (%), fechados (%), em aberto (n); e uma
  linha menor com PRs entregues, mediana até o merge e rodadas de review por PR.
- `usage_table`-like "Por pipeline".
- Tabela "Retrabalho por etapa" (Petal `.table`/`.tr`/`.td` como a de "Por etapa").
- Lista "Etapas que mais pausam" (cards de ADR 0052 / `.card` com linhas).
- "Aceitos sem alteração por semana" em barras simples como "Custo por dia".
- Estado vazio (`usage-quality-empty`) quando não há PR no período, com a explicação de que só
  contam tarefas de repositórios ligados entregues em PR.
- Nota quando `untracked > 0`: "N PRs sem leitura de commits (integração no modo runner)".

`data-testid` (padrão de `e2e/README.md`, por registro com chave natural):
`usage-tab-qualidade` (vem de `page_tabs`), `usage-quality-empty`,
`usage-quality-clean`, `usage-quality-changed`, `usage-quality-closed`, `usage-quality-open`,
`usage-quality-delivered`, `usage-quality-merge-time`, `usage-quality-review-rounds`,
`usage-quality-untracked`, `usage-quality-by-pipeline`, `usage-quality-pipeline-<nome>`,
`usage-quality-stages`, `usage-quality-stage-<pipeline>-<key>` (com
`…-retries`, `…-redone`, `…-decisions`, `…-review-fixes`, `…-merge-fixes`),
`usage-quality-pauses`, `usage-quality-pause-<pipeline>-<key>`, `usage-quality-week-<data>`,
`usage-project` (select novo). Conferir as attrs reais em `docs/guias/ui-petal.md`.

## Testes

ExUnit (`apps/pipe_maestro`):

- `test/pipe_maestro/integrations/pr_outcomes_test.exs`:
  - `ready/1` grava uma vez; uma correção depois (novo `finished_at`) não muda `ready_at`;
  - `observe/2` com lista simulada: entrega do pipeline absorve os SHAs até a head; SHA depois
    da head e SHA novo com a tarefa parada viram humanos; commit de merge ignorado; duas
    leituras iguais não mudam nada (critério 4).
- `test/pipe_maestro/integrations/conversation_test.exs` (estender), GitHub **e** Forgejo com
  `test/support/fake_github.ex` / `fake_forgejo.ex` ganhando `pulls/:n/commits`:
  - critério 1: commits do PR com SHA não empurrado → `:pr_closed` mergeado →
    `:accepted_changed`;
  - critério 2: review rejeitado → "Correção 1" com `origin: :review`, `review_rounds == 1` →
    merge → `:accepted_changed`; o mesmo review reprocessado → ignorado, 1 rodada, 1 correção;
  - critério 3: merge limpo → `:accepted_clean`; fechado sem merge → `:closed`;
  - critério 4: o mesmo `:pr_closed` duas vezes não muda datas nem contagens.
- `test/pipe_maestro/integrations/github_test.exs`, `forgejo_test.exs`: `pr_commits/3` com
  paginação; `get_pr/3` com `merged_at`; parse de `merged_at` no evento.
- `test/pipe_maestro/integrations/reconciler_test.exs`: PR mergeado sem webhook é pego por
  `get_pr/3`; erro de API grava `commits_error` e a passagem segue.
- `test/pipe_maestro/integrations/auto_merge_test.exs`: correção com `origin: :auto_merge`,
  merge grava o desfecho.
- `test/pipe_maestro/usage_test.exs`: `quality/3` num cenário montado (stage_runs com
  `attempt` 1–3 e `requeue`, decisões `:retry`/`:advance`/`:cancel`/`:correct` de cada origem,
  uma tarefa em `awaiting_decision`), batendo cada coluna (critério 5); filtros de período
  (`ready_at` dentro/fora), pipeline e projeto (critério 6); mediana e `by_week`.
- `test/pipe_maestro/tasks_test.exs`: `correct/3` grava `origin`; `finish/2` cria o desfecho.

ExUnit (`apps/pipe_maestro_web`):

- `test/pipe_maestro_web/live/usage_live_test.exs`: `?aba=qualidade` com dados, estado vazio,
  troca de pipeline e de projeto mudando os números (critério 6).

Playwright:

- `e2e/tests/usage-quality.spec.ts` (critério 7): cria workspace e admin pelo backoffice como as
  outras specs, semeia via `mix run` no ambiente `e2e` (helper novo
  `e2e/helpers/qualitySeed.ts`, no molde de `ensureBootstrapOperator` em `e2eState.ts`, que
  roda o script `e2e/support/usage_quality_seed.exs` com o slug do workspace; o script insere
  pipeline, projeto, tarefas, stage_runs, decisões e desfechos pelo `Repo`), abre `?aba=qualidade` e confere cartões, tabela por pipeline, retrabalho e pausas por
  `data-testid`; troca o pipeline e o projeto; `shot(...)` para `make e2e.shots`.

## Documentação

- **ADR 0053** `docs/adr/0053-qualidade-das-entregas.md`: tabela de desfecho e por que fora de
  `tasks`; `ready_at`; critério de commit humano por SHA e posição (D2) e suas limitações
  (commit humano durante a etapa, force-push, limite de 250 commits do GitHub, modo `runner`);
  merge commits ignorados; `decisions.origin`; pausas derivadas de decisões; período por
  `ready_at` x por evento; mediana e semana.
- `docs/specs/integracoes.md`: §1 (modelo de dados: `PrOutcome`), §2 (`pr` com `merged_at`/
  `closed_at`), §7 (o que cada evento de PR grava; fechado sem merge agora registra), seção nova
  "Desfecho do PR" com `pr_commits/3` (endpoints de GitHub e Forgejo) e o passo do Reconciler.
- `docs/specs/maquina-de-estados-tarefa.md`: só uma linha sobre `Decision.origin` se ela listar
  os campos da decisão.
- `AGENTS.md`: a linha de `Integrations` ganha "o desfecho de cada PR entregue"; a de `Usage`
  (hoje implícita) passa a dizer "custo e qualidade das entregas". Não há contexto novo.
- `UsageLive` `@moduledoc` e `Usage` `@moduledoc` atualizados.

## Riscos

- **Migrações**: aditivas (tabela nova, coluna nula). O preenchimento de `decisions.origin` é
  um `UPDATE` simples. Sem risco para dados existentes; tarefas antigas ficam sem desfecho.
- **Concorrência**: `observe/2` roda no `FeedbackWorker` (um por tarefa via
  `Integrations.background/1`) e no Reconciler; as escritas são `UPDATE` com união de arrays
  (`array(SELECT DISTINCT unnest(a || b))`) e condições (`state = 'open'`), então duas
  observações juntas não perdem nem duplicam SHA. `review_round/2` é um único `UPDATE`
  condicional.
- **Corrida do D2**: commit humano incorporado pelo runner durante uma etapa conta como do
  pipeline (documentado). A observação ao começar uma etapa é assíncrona; o push da etapa leva
  minutos, então na prática ela chega antes.
- **API do host**: chamadas novas só em segundo plano; falha vira `commits_error` e o
  Reconciler tenta de novo. Nada no caminho da tarefa (`Tasks`) chama o host.
- **Custo de API**: `observe/2` só para desfechos `open` (e a leitura final); o Reconciler só
  para pendentes.
- **Cobertura**: módulos novos com testes próprios; o threshold de 60% por app não preocupa.
- **Dialyzer**: tipos de `Usage.quality()` e do mapa de commit; `Decision.action`/`origin` com
  `Ecto.Enum` tipado; `pr_commits/3` declarada em `Provider` e nos dois providers (e nos fakes
  de teste, se implementarem o behaviour).
- **e2e**: a semente direta no `Repo` precisa acompanhar os schemas; fica num só script.
