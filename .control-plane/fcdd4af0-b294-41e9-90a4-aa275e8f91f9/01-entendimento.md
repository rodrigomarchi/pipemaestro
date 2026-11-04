# Etapa 1 — Entendimento e plano: "Últimas execuções" na página do runner

## Contexto lido

- `AGENTS.md`/`CLAUDE.md`: fronteiras do umbrella, `@spec`/`@moduledoc`, LiveViews finas,
  Petal antes de Tailwind, `data-testid` em tudo o que um teste toca, `make ci` + `make e2e`.
- ADR 0010 §7: define o que a página do runner (`/w/:slug/runners/:id`) mostra hoje
  (agente, capacidade, worktrees, jobs ativos, diretórios). ADR 0015: auditoria da execução,
  que vive na página do job (`/w/:slug/jobs/:id`, `data-testid="job-audit"`).
- `apps/pipe_maestro_web/lib/pipe_maestro_web/live/runner_live.ex`: já assina
  `Jobs.subscribe({:workspace, id})` e recarrega tudo em `{:job_updated, _}`.
- `apps/pipe_maestro/lib/pipe_maestro/jobs.ex`: `active_for_runner/1`,
  `finish_job/3` → `notify/1` faz broadcast de `{:job_updated, job}` em `{:workspace, id}`;
  o mesmo acontece em `request_cancel/1` (fila) e `reconcile/2` (via `update!/2`).
- `jobs/job.ex`: `cost_usd`, `duration_ms`, `wall_ms`, colunas de tokens, `Job.tokens/1`,
  `Job.cache_hit/1`, `Job.finished_statuses/0`, `belongs_to :stage_run`
  (`StageRun` tem `name`, `key`, `attempt`, `belongs_to :task`; `Task` tem `title`).
- `components/job_components.ex`: `job_status/1`, `prompt_summary/2`, `format_duration/1`,
  `format_cost/1`, `short_number/1`, `format_percent/1` — tudo reutilizável.
- `e2e/tests/runner-connection.spec.ts` (fluxos A/B/C) e `job-execution.spec.ts` (o runner real
  com o `claude` falso conclui um job com custo `US$ 0.0042`, duração `1 s`, cache `91%`).

## 1. Especificação

### O que muda para quem usa

Na página de um executor aparece um card **"Últimas execuções"**, entre "Jobs em execução e
na fila" e "Diretórios", com as **10 execuções mais recentes que esse runner terminou**, da
mais recente para a mais antiga (por `finished_at`, desempate por `id`).

Cada linha mostra:

| Coluna | Origem | Sem dado |
|---|---|---|
| Status | `<.job_status job={job} />` (Concluído / Falhou / Cancelado) | — |
| O quê | execução avulsa: `prompt_summary(job.prompt)`; etapa de pipeline: **título da tarefa · nome da etapa** (com "tentativa N" quando `attempt > 1`) | — |
| Duração | `format_duration(job.duration_ms || job.wall_ms)` | "—" |
| Custo | `format_cost(job.cost_usd)` | "—" |
| Tokens | `short_number(Job.tokens(job))` | "—" quando nenhuma coluna de tokens foi informada |
| Cache | `format_percent(Job.cache_hit(job))` | "—" (sem input) |

A linha inteira (o texto "O quê") é um link para `/w/:slug/jobs/:id`, onde está a auditoria.

Sem execuções terminadas, o card mostra: *"Este runner ainda não terminou nenhuma execução."*

A lista **se atualiza ao vivo**: quando uma execução desse runner termina (concluída,
falhou, cancelada, ou falhou por reinício do runner), ela entra no topo, e a 11ª sai.

### Decisões de interpretação (não bloqueiam; registradas aqui)

- **"Terminou" = status em `Job.finished_statuses/0` e `started_at` não nulo.** Um job
  cancelado ainda na fila nunca rodou no runner, então não entra. Jobs que o `reconcile/2`
  marca como falhos (o runner reiniciou) entram: eles começaram nesse runner.
- **Ordem por `finished_at desc, id desc`**, não por `inserted_at`: o card é sobre o que
  terminou por último.
- **Duração:** `duration_ms` (o que o CLI informou, o mesmo da lista de execuções), com
  `wall_ms` (cronometrado pelo runner) como reserva; nenhum dos dois → "—".
- **Escopo do workspace:** a consulta filtra por `workspace_id` **e** `runner_id`. O runner
  já é carregado com `Runners.get_runner!(workspace, id)` (outro workspace → 404), e o filtro
  extra impede que um job de outro workspace apareça mesmo que algum dia aponte para esse
  runner.

### Casos de borda

- Runner sem nenhuma execução, ou só com jobs ativos/na fila → estado vazio
  (`runner-no-recent-jobs`); os ativos continuam no card "Jobs em execução e na fila".
- Mais de 10 terminadas → só as 10 mais recentes.
- Job de etapa cuja tarefa/etapa existe (sempre existe: `stage_run_id` é FK) → título · etapa;
  se `stage_run` for `nil` → resumo do prompt.
- Job que falhou sem métricas (reconcile, erro antes do `result`) → duração, custo, tokens e
  cache com "—".
- Execução terminada de **outro runner** do mesmo workspace não entra; de **outro workspace**
  não entra.
- Runner revogado: a página continua igual (o card lista o histórico).
- A atualização ao vivo de um job de outro runner não deve mudar o card (recarregar é
  inofensivo, mas evitamos a consulta: só recarregamos quando `job.runner_id` é o runner da
  página).

### Critérios de aceite

1. CA1 — O card "Últimas execuções" aparece na página do runner (`runner-recent-jobs`).
2. CA2 — Lista no máximo 10 execuções terminadas pelo runner, mais recentes primeiro;
   jobs na fila ou em execução e jobs cancelados antes de começar não aparecem.
3. CA3 — Cada linha mostra status, prompt resumido (ou tarefa · etapa), duração, custo,
   tokens e % de cache, com "—" quando faltar o dado.
4. CA4 — Cada linha leva à página da execução (`/w/:slug/jobs/:id`).
5. CA5 — Sem execuções terminadas, o card diz que o runner ainda não terminou nenhuma.
6. CA6 — Quando uma execução do runner termina, a linha aparece sem recarregar a página.
7. CA7 — Só aparecem execuções do workspace atual e desse runner.
8. CA8 — `make ci` verde; `make e2e` verde com o card conferido no `runner-connection`
   e capturas claro/escuro.

## 2. Plano

### Apps tocados (dentro das fronteiras)

- **`pipe_maestro` (domínio):** nova função de consulta em `Jobs`. Sem web.
- **`pipe_maestro_web`:** `RunnerLive` e (opcional) um componente de linha.
- **`protocol` e `runner`: nada.** Não há mudança no protocolo runner ↔ control plane: os
  dados (custo, duração, tokens, cache) já chegam em `job:finish` e já estão em `jobs`.
- **Migrations: nenhuma.** O índice `jobs(runner_id, status)` atende o filtro; o volume por
  runner é pequeno e o `limit 10` fecha a consulta (ver Riscos).

### Arquivos

1. `apps/pipe_maestro/lib/pipe_maestro/jobs.ex`
   - `@doc` + `@spec recent_for_runner(Workspace.t(), Runner.t(), pos_integer()) :: [Job.t()]`
     com `limit \\ 10` (atributo `@recent_limit 10`):
     ```elixir
     from j in Job,
       where: j.workspace_id == ^workspace_id and j.runner_id == ^runner_id and
              j.status in ^Job.finished_statuses() and not is_nil(j.started_at),
       order_by: [desc: j.finished_at, desc: j.id],
       limit: ^limit,
       preload: [stage_run: :task]
     ```
   - Atualizar o `@moduledoc` de `Jobs` se ele enumerar as consultas (sem contagens).
2. `apps/pipe_maestro_web/lib/pipe_maestro_web/live/runner_live.ex`
   - `@moduledoc`: incluir "as últimas execuções que terminou, que levam à auditoria".
   - `load/1` passa a atribuir `recent_jobs: Jobs.recent_for_runner(workspace, runner)`;
     extrair `load_recent/1` para que `handle_info({:job_updated, %Job{runner_id: id}}, …)`
     recarregue o card só quando `id == socket.assigns.runner_id` (os jobs ativos também só
     mudam nesse caso; presença/`:runners_changed` não recarregam o histórico).
   - Novo `<.card variant="outline">` com `<.card_header title="Últimas execuções"
     description="As 10 mais recentes que este runner terminou; cada uma leva à auditoria." />`.
     Conteúdo: Petal `<.table id="runner-recent-jobs-table" rows={@recent_jobs}
     row_id={&"runner-recent-job-#{&1.id}"}>` com as colunas acima (mesmo padrão da
     `JobsLive`), ou `<.empty>`/parágrafo quando vazio. Conferir as attrs reais de
     `<.table>`/`<.empty>` em `docs/guias/ui-petal.md` antes de escrever o HEEx.
   - Helper privado (ou em `JobComponents`, se a lista de tarefas também puder usar) para
     o rótulo "tarefa · etapa": `job_label(%Job{stage_run: %StageRun{} = sr})` →
     `"#{sr.task.title} · #{sr.name}"` (+ `" (tentativa #{sr.attempt})"` se `attempt > 1`);
     senão `prompt_summary(job.prompt, 70)`. Como é apresentação, pode ficar na web.
   - Tokens: `short_number` só quando algum campo de tokens não é `nil`; senão "—"
     (helper pequeno, p.ex. `format_tokens/1` em `JobComponents`, com `@spec`).
3. `e2e/pages/RunnersPage.ts`: `openRunner(slug, name)` (clica em `runner-link-{name}`),
   `recentJobs`, `recentJob(id)` e `noRecentJobs` como locators por test id.
4. `e2e/tests/runner-connection.spec.ts`: novo trecho do fluxo B (ver §3) e a linha
   `@flow` correspondente no cabeçalho.

### `data-testid` novos

| test id | elemento |
|---|---|
| `runner-recent-jobs` | o card |
| `runner-no-recent-jobs` | o estado vazio |
| `runner-recent-job-{job_id}` | a linha (`row_id` da tabela) |
| `runner-recent-job-link-{job_id}` | o link para a execução |
| `runner-recent-job-status-{job_id}` | o status |
| `runner-recent-job-duration-{job_id}` | a duração |
| `runner-recent-job-cost-{job_id}` | o custo |
| `runner-recent-job-tokens-{job_id}` | os tokens |
| `runner-recent-job-cache-{job_id}` | o % de cache |

(O registro natural de um job é o id; não há slug.)

### Ordem

1. Domínio: `Jobs.recent_for_runner/3` + testes em `jobs_test.exs`.
2. Web: `RunnerLive` (load, handle_info, card) + helpers + testes em `runner_live_test.exs`.
3. `mix format`, `make ci.quick` durante a iteração.
4. e2e: page object + spec; `make e2e`, `make e2e.shots` e leitura das capturas claro/escuro.
5. Documentação; `make ci` no fim.

## 3. Testes por critério

### ExUnit — domínio (`apps/pipe_maestro/test/pipe_maestro/jobs_test.exs`)

`describe "recent_for_runner/3"`:
- CA2: cria jobs no runner com `job_fixture` + `mark_started` + `finish_job` (succeeded,
  failed, canceled), mais um na fila, um em execução e um cancelado na fila
  (`request_cancel` em `:queued`) → só os três terminados que começaram, ordem
  `finished_at desc` (ajustar `finished_at` via `Repo.update_all` para tempos distintos, já que
  `now/0` tem resolução de segundo).
- CA2: com 12 terminadas e `limit` padrão → 10, as mais recentes.
- CA7: job terminado de outro runner do mesmo workspace e de um runner de outro workspace
  não aparecem; chamar com o workspace errado para o runner retorna `[]`.
- CA3 (dado): um job de etapa (via `Tasks.create_task/3` como em `task_live_test.exs`,
  terminado com `finish_job`) volta com `stage_run.task` carregado.
- Job falho por `reconcile/2` aparece.

Se `format_tokens/1` (ou o rótulo tarefa · etapa) for para `JobComponents`, testes de
unidade no app web (`job_components_test.exs`, se existir; senão via LiveView).

### ExUnit — LiveView (`apps/pipe_maestro_web/test/pipe_maestro_web/live/runner_live_test.exs`)

- CA1/CA5: runner sem execuções → `runner-recent-jobs` presente e `runner-no-recent-jobs`
  com o texto "ainda não terminou nenhuma".
- CA6/CA3: com a página aberta, cria job, `mark_started`, `finish_job` com `cost_usd`,
  `duration_ms`, `usage` (fresh_input/cache_read/cache_creation/output) → a linha
  `runner-recent-job-{id}` aparece sem novo `live/2`, com "Concluído", "investigue o login",
  duração, `US$ …`, tokens e "%"; `runner-no-recent-jobs` some.
- CA3: job falho sem métricas → "—" em duração/custo/tokens/cache.
- CA3: job de etapa mostra "título · etapa" em vez do prompt.
- CA4: `element("[data-testid=runner-recent-job-link-#{id}]") |> render_click()` →
  `{:error, {:live_redirect, %{to: "/w/#{slug}/jobs/#{id}"}}}`.
- CA2: job na fila/rodando aparece em "Jobs em execução" e **não** no card novo.
- CA7: um job terminado de outro runner do workspace não aparece (e não dispara recarga
  do histórico — basta verificar a ausência).

### e2e (`e2e/tests/runner-connection.spec.ts`)

No fluxo B, depois do runner ficar online:
1. Abrir a página do runner (`runner-link-{runnerName}`), verificar
   `runner-no-recent-jobs` visível; `shot(page, "runner-detail-no-recent-jobs")`.
2. Mandar um prompt pelo `JobsPage.create(runnerName, prompt)` (o `claude` falso conclui com
   `US$ 0.0042`, `1 s`, cache `91%`), esperar "Concluído".
3. Voltar à página do runner: `runner-recent-job-status-{id}` = "Concluído",
   `runner-recent-job-cost-{id}` = "US$ 0.0042", `runner-recent-job-cache-{id}` = "91%",
   link contém o início do prompt; clicar no link leva à página da execução com `job-audit`
   visível.
4. `shot(page, "runner-recent-jobs")` — o helper `shot` gera claro e escuro (conferir em
   `e2e/helpers/screenshots.ts`); ler as duas capturas em `make e2e.shots`.
5. Atualizar o cabeçalho: `@flow D [done] A runner's page lists the latest jobs it finished,
   each leading to its audit` (o fluxo C de revogação segue depois, com o runner renomeado).

A atualização ao vivo fica provada no ExUnit (CA6); no e2e, opcionalmente, manter a página
do runner aberta numa segunda aba do mesmo contexto enquanto o job roda.

## 4. Documentação

- **Sem ADR novo:** não há decisão de arquitetura (nem protocolo, nem esquema); é uma
  consulta e um card. Se a revisão preferir registrar, um parágrafo no ADR 0015 (auditoria)
  bastaria: "a página do runner lista as últimas execuções terminadas e leva à auditoria".
- `docs/plano/03-roadmap-orquestrador.md`: acrescentar o item na seção da página do runner /
  auditoria, marcado ✓.
- `docs/guias/instalacao.md` (trecho que fala da página do runner): uma frase dizendo que ela
  mostra as últimas execuções terminadas.
- `@moduledoc` de `RunnerLive` e `@doc` de `Jobs.recent_for_runner/3`.
- `e2e/README.md`: só se ele listar os fluxos/capturas por nome.
- Specs (`docs/specs/protocolo-runner.md`): **sem mudança**.

## 5. Riscos

- **Recarga a cada `job_updated` do workspace:** hoje a `RunnerLive` recarrega tudo para
  qualquer job do workspace; com a consulta nova isso dobraria as idas ao banco. Mitigação:
  filtrar pelo `runner_id` do job no `handle_info`.
- **Desempenho da consulta:** usa o índice `jobs(runner_id, status)` e ordena por
  `finished_at` em memória; aceitável para o volume por runner. Se crescer muito, um índice
  `jobs(runner_id, finished_at)` resolve — fora do escopo.
- **Resolução de segundo em `finished_at`:** jobs terminados no mesmo segundo empatam; o
  desempate por `id` (UUID) é estável mas não cronológico. Nos testes, fixar `finished_at`
  distintos.
- **e2e mais longo e acoplado ao `claude` falso:** o `runner-connection` passa a rodar um
  job; reaproveitar `JobsPage` e o mesmo runner evita um segundo processo. Os valores
  (`US$ 0.0042`, `91%`) vêm do `claude` falso e já são usados em `job-execution.spec.ts`.
- **Largura do card:** seis colunas numa página que não é tabela larga; conferir nas
  capturas (claro/escuro, e se houver, mobile) que o prompt trunca e as colunas não
  estouram.
- **Interpretação de "terminou":** excluir cancelados que nunca começaram é uma escolha;
  se o produto quiser vê-los, basta tirar o filtro `started_at`.
