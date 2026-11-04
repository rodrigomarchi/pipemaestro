# Etapa 4 — Revisão de código: "Últimas execuções" na página do runner

Revisado: `git diff main...HEAD` (nada fica fora do commit), contra a especificação e o plano
de `01-entendimento.md`, os testes de `02-testes.md` e o relato de `03-implementacao.md`.

## Veredito

**Nenhum problema grave.** A mudança cumpre CA1–CA7 no código e nos testes ExUnit e respeita
as fronteiras do umbrella. A consulta fica no domínio, a apresentação fica na web, e
protocolo, runner e migrations não mudam. Fica uma pendência de **verificação** (CA8),
descrita abaixo, que precisa ser fechada fora desta sessão antes do merge.

## Conferências feitas

- **Fronteiras:** `Jobs.recent_for_runner/3` fica em `pipe_maestro`, sem nada de web.
  `RunnerLive` só chama o contexto e formata. Protocolo e runner não mudam.
- **`@spec`/`@doc`/`@moduledoc`:** a função pública nova tem `@doc` e `@spec`. O `@moduledoc`
  de `RunnerLive` foi atualizado. Os helpers novos são privados.
- **LiveView fina:** sem regra de negócio; o filtro de "terminou" fica no domínio.
- **Reaproveitamento:** usa `job_status/1`, `prompt_summary/2`, `format_duration/1`,
  `format_cost/1`, `format_percent/1`, `short_number/1`, `Job.tokens/1` e `Job.cache_hit/1`,
  que já existiam.
- **`finished_at` nunca é nulo num job terminado:** `Job.finish_changeset`
  (`jobs/job.ex:223`), `request_cancel` (`jobs.ex:168`) e `reconcile` (`jobs.ex:242`) o
  preenchem. Assim, `order_by desc` não sofre com os NULLs que o Postgres põe primeiro.
- **`handle_info({:job_updated, %Job{}})`:** todos os broadcasts em `{:workspace, id}`
  (`jobs.ex:70`, `:98`, `:439`) mandam um `%Job{}`, então o padrão mais estrito não deixa
  mensagem sem cláusula.
- **`data-testid`:** os do plano estão todos no HEEx, e o e2e seleciona só por test id. O
  `.card` repassa `data-testid` (o teste de LiveView que o procura passa).
- **Petal:** `<ul>/<li>` em vez de `<.table>` é um desvio do plano, justificado: o `row_id`
  do Petal não dá `data-testid`, e o card vizinho "Jobs em execução" já usa o mesmo padrão.
- **Comentários:** descrevem o código e não a mudança. A documentação não tem contagens; a
  descrição do card evita "10".
- **e2e:** `JobsPage.create/2` devolve o id e `jobs.status` existe (mesmo uso de
  `job-execution.spec.ts`). O `RunnerProcess` usa o `claude` falso, de onde vêm os valores
  `US$ 0.0042`, `1 s` e `91%`. O fluxo C reabre a lista antes de renomear.

## Problemas, por severidade

### Importante — verificação pendente (não é defeito de código)

1. **CA8 não verificado: `make ci` completo, `make e2e` e `make e2e.shots` não rodaram.**
   O relato da implementação diz que o ambiente herda `__BURRITO`, e isso derruba qualquer VM
   que carregue o app do runner. Esta revisão também não pôde rodar comandos. Portanto:
   - o trecho novo de `e2e/tests/runner-connection.spec.ts:67-89` nunca rodou;
   - as capturas `runner-detail-no-recent-jobs` e `runner-recent-jobs` não foram lidas em
     claro e escuro. O `AGENTS.md` e `.claude/rules/ui.md` exigem isso para telas.

   O risco mais concreto é visual: o `<dl>` com `shrink-0` e quatro métricas ao lado de um
   link `truncate` (`runner_live.ex:210-246`) em larguras médias.
   **Antes do merge:** `make ci` e
   `make e2e.shots FILE=tests/runner-connection.spec.ts`, fora de um job do runner em
   binário.
2. **Achado de outra tarefa (registrado pela implementação, confirmo que é relevante):** o
   `pipemaestro` em binário passa `__BURRITO` para o `claude` e para os comandos do agente.
   Assim, nenhuma etapa que trabalhe neste repositório consegue rodar `make ci`/`make e2e`.
   Merece uma issue própria. Ela não muda este diff.

### Menor

3. **Rótulo de job de etapa inconsistente entre os dois cards da mesma página.**
   `runner_live.ex:176` (jobs ativos) mostra `prompt_summary(job.prompt)`. O card novo mostra
   "tarefa · etapa" (`runner_live.ex:279-284`). O mesmo job muda de nome ao sair de
   "em execução" para "últimas execuções". Duas formas de resolver:
   - pré-carregar `stage_run: :task` em `active_for_runner/1` e usar `job_label/1` nos dois;
   - mover `job_label/1` para `JobComponents` e reaproveitá-lo.
4. **Regra de "tokens sem dado" duplicada.** `tokens/1` (`runner_live.ex:287-292`) repete o
   critério `Job.tokens(job) > 0` de `task_live/show.ex:775`. O plano previa um
   `format_tokens/1` público em `JobComponents`, com `@spec`, e teria uma fonte única. Um
   job que informou tokens todos zero também aparece como "—". Isso é aceitável, mas vale
   documentar no helper compartilhado.
5. **Ramos sem teste:**
   - "(tentativa N)" para `attempt > 1` (`runner_live.ex:280`);
   - a reserva `wall_ms` quando `duration_ms` é nulo (`runner_live.ex:222`).

   Os dois são de uma linha e a cobertura está acima do limite, mas cada um é um caso de
   borda da especificação (CA3).
6. **O teste "another runner's finished job is not listed"**
   (`runner_live_test.exs:191-201`) prova só a ausência da linha. Ele não prova que o
   `handle_info` deixou de recarregar, que era a motivação do filtro por `runner_id`. Isso é
   aceitável (o plano dizia "basta verificar a ausência"); fica registrado.
7. **Ordem do cabeçalho `@flow`** em `runner-connection.spec.ts:5`: D aparece entre B e C,
   seguindo a ordem de execução, mas as letras ficam fora de sequência. Isso é cosmético.
   Renomear para C e passar a revogação para D deixaria a leitura direta, se o `e2e/README.md`
   não amarrar as letras às capturas.

## Recomendação

Pode seguir. Os itens 3–5 são melhorias pequenas que cabem num ajuste antes do PR. O item 1 é
obrigatório antes do merge, mas depende de um ambiente sem `__BURRITO`, não de mudança no
código.
