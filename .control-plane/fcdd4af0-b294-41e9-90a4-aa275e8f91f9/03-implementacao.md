# Etapa 3 — Implementação: "Últimas execuções" na página do runner

Os testes da etapa 2 passam sem alteração. Protocolo, runner e migrations não mudaram.

## O que mudou

### `apps/pipe_maestro/lib/pipe_maestro/jobs.ex`

`Jobs.recent_for_runner/3` deixa de ser um stub. A consulta filtra por `workspace_id` **e**
`runner_id`, `status in Job.finished_statuses()` e `started_at` não nulo, porque um job
cancelado na fila nunca rodou no runner. Ordena por `finished_at desc, id desc`, aplica
`limit` (padrão 10) e pré-carrega `stage_run: :task`. O `@doc` explica por que os
cancelados antes de começar ficam de fora.

### `apps/pipe_maestro_web/lib/pipe_maestro_web/live/runner_live.ex`

- `@moduledoc`: a página também lista as últimas execuções terminadas, cada uma levando
  à auditoria.
- `load/1` atribui `recent_jobs: Jobs.recent_for_runner(workspace, runner)`.
- `handle_info({:job_updated, %Job{runner_id: id}}, …)` só recarrega quando o job é do
  runner da página. Antes, qualquer job do workspace provocava uma recarga, e agora cada
  recarga faz uma consulta a mais.
- Novo card `runner-recent-jobs`, entre "Jobs em execução e na fila" e "Diretórios":
  - estado vazio `runner-no-recent-jobs`;
  - uma `<li>` por job (`runner-recent-job-{id}`) com:
    - status (`<.job_status>`);
    - link para `/w/:slug/jobs/:id` (`-link-`);
    - duração (`duration_ms`, com `wall_ms` de reserva, `-duration-`);
    - custo (`-cost-`), tokens (`-tokens-`) e % de cache (`-cache-`).
- Os formatadores já existiam em `JobComponents` (`format_duration`, `format_cost`,
  `format_percent`, `short_number`, `prompt_summary`); só o `import` ficou mais longo.
- Dois helpers privados:
  - `job_label/1`: "tarefa · etapa" (com "(tentativa N)" quando `attempt > 1`), ou o
    resumo do prompt;
  - `tokens/1`: "—" quando nenhuma coluna de tokens foi informada.
- **Desvio do plano: lista `<ul>/<li>` em vez de `<.table>`.** O `<.table>` do Petal só
  põe `id` na linha (`row_id`), e o teste procura a linha por `data-testid`. O card
  "Jobs em execução" ao lado já usa `<ul>/<li>`, então os dois ficam iguais. Os números
  ficam num `<dl>` com rótulos `sr-only` e `title`.

### `e2e/pages/RunnersPage.ts`

`openRunner(slug, name)` (pela lista, clicando em `runner-link-{name}`), `recentJobs`,
`noRecentJobs` e `recentJob(id, part?)`, que devolve a linha ou uma das células.

### `e2e/tests/runner-connection.spec.ts`

Fluxo D, entre B e C, registrado no cabeçalho com `@flow D`:

1. A página do runner sem execuções; captura `runner-detail-no-recent-jobs`.
2. Um prompt pelo `JobsPage`, até "Concluído".
3. De volta à página do runner, a linha mostra:
   - status "Concluído";
   - o prompt;
   - duração "1 s";
   - custo "US$ 0.0042";
   - cache "91%".
4. Captura `runner-recent-jobs`.
5. O link abre a execução com `job-audit` visível.

Depois, o fluxo C reabre a lista de runners antes de renomear.

### Documentação

- `docs/plano/03-roadmap-orquestrador.md`: item ✓ na seção do diagnóstico e da página do
  runner.
- `docs/guias/instalacao.md`: um item "Histórico" sobre a página do runner.

## Saída dos testes

```
$ cd apps/pipe_maestro && mix test test/pipe_maestro/jobs_test.exs
Result: 21 passed

$ cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/live/runner_live_test.exs
Result: 9 passed

$ cd apps/pipe_maestro && mix test --warnings-as-errors --cover
Result: 149 passed (1 doctest, 148 tests)      Total 93.69%  (Jobs 96.15%)

$ cd apps/pipe_maestro_web && mix test --warnings-as-errors --cover
Result: 181 passed                             Total 95.55%  (RunnerLive 97.89%)

$ cd apps/pipe_maestro_protocol && mix test --warnings-as-errors --cover
Result: 40 passed                              Total 90.24%

$ make ci.quick   # passos até o mix test
compile --warnings-as-errors: ok · format --check-formatted: ok · deps.unlock --check-unused: ok
credo --strict: found no issues

$ make dialyzer
Total errors: 0 · done (passed successfully)

$ make e2e.typecheck
ok (tsc --noEmit sem erros)
```

## O que não deu para rodar aqui

Nesta sessão não rodaram:

- os testes do app `pipe_maestro_runner`;
- o `mix test` a partir da raiz (passo 5 de `make ci`);
- o `make e2e` / `make e2e.shots`.

Todos param no boot com o uso do `pipemaestro` e saída 2:

```
pipemaestro login --url https://plataforma.exemplo.com
    pipemaestro start [--root ~/src]
    pipemaestro status | logout | doctor
    pipemaestro service print | install | uninstall
```

**Causa:** o ambiente desta execução herdou `__BURRITO` do `pipemaestro` em binário único
(Burrito) que roda o pipeline. Com ela presente,
`PipeMaestroRunner.Application.standalone/1` acredita estar no binário: chama
`Main.run/1` com os argumentos da VM e faz `System.halt/1`. Isso acontece em qualquer VM
que carregue o app do runner (testes do runner, `mix test` da raiz, o servidor do e2e).
Nada disso vem desta mudança, que não toca o runner. Não consegui rodar com
`env -u __BURRITO` porque o comando pede aprovação e esta sessão não tem quem aprove.

**Achado para outra tarefa:** o runner em binário passa `__BURRITO` adiante para o
processo `claude` que ele inicia, e daí para os comandos do agente. Quando o pipeline
trabalha neste próprio repositório, nenhum `make ci` ou `make e2e` passa dentro de uma
etapa. A correção natural é tirar `__BURRITO` do ambiente depois de detectá-la em
`standalone/2`, ou do ambiente do `claude` no `JobRunner`. Não fiz essa correção aqui:
ela muda o runner e não daria para validá-la nesta sessão, onde os testes do runner não
rodam.

**Para fechar o CA8**, rode fora de um job do runner em binário:

- `make ci`;
- `make e2e.shots FILE=tests/runner-connection.spec.ts`, conferindo as capturas
  `runner-detail-no-recent-jobs` e `runner-recent-jobs` em claro e escuro: largura da
  linha, prompt truncado, números que quebram para baixo em telas estreitas (`flex-wrap`).
