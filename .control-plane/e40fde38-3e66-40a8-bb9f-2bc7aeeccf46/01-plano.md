# Etapa 1 — Entendimento e plano: "Os alertas do Board"

## Entendimento

### Como está hoje (lido no código)

- `PipeMaestro.Tasks.alerts/2` (`apps/pipe_maestro/lib/pipe_maestro/tasks.ex`) calcula,
  para as tarefas `:running`/`:awaiting_decision` do workspace, `{:runner_offline, task}`,
  `{:decision_overdue, task}`, `{:near_budget, task, spent, cap}` e
  `{:runner_near_limit, task, runner}` (este via `Runners.near_limit?/2`, que considera
  `rate_limit["resets_at"]`). A presença online entra como `MapSet` de ids.
- `PipeMaestroWeb.RunnerStatus` (`apps/pipe_maestro_web/lib/pipe_maestro_web/runner_status.ex`)
  publica no tópico `workspace_runners:<id>` dois sinais: o `presence_diff`
  (`RunnerPresence`, quando o canal do runner entra ou morre) e `:runners_changed`
  (`notify_changed/1`).
- `RunnerChannel` (`channels/runner_channel.ex`) já chama `notify_changed/1` no
  `after_join`, em `runner:directories`, `worktree:usage` e **depois de um `job:event` do
  tipo `rate_limit`** (`Jobs.append_event/3` → `Runners.record_rate_limit/2`). Ou seja, o
  sinal já existe; o problema está em quem escuta.
- `BoardLive` (`live/board_live.ex`):
  - `presence_diff` → `load_runners/1 |> load_tasks/1`. Os alertas são recalculados, mas
    junto vai tudo de `load_tasks/1`: `list_tasks` duas vezes, `list_awaiting`, `stats`.
    É mais do que o necessário.
  - `:runners_changed` → só `load_runners/1`. **O alerta de limite não aparece ao vivo**,
    e a volta do runner só é refletida pelo `presence_diff`.
  - Quando o limite renova (o `resets_at` passa) não chega evento nenhum. O alerta
    `runner_near_limit` só some quando algo recarrega a tela.
- Outras telas:
  - `TaskLive.Index` (`live/task_live/index.ex`) e `JobsLive` (`live/jobs_live.ex`): já
    escutam `presence_diff` e `:runners_changed` e recarregam `online_runners`, que só
    alimentam o formulário de criação (select de runners online). Elas não mostram
    alertas nem o estado do runner por tarefa ou job. **Não têm o problema e não mudam.**
  - `RunnersLive`, `RunnerLive` e `UsageLive` já recarregam com os dois sinais. Elas
    mostram estado e limite do runner, não alertas de tarefa. **Não mudam.**
  - `TaskLive.Show` (`live/task_live/show.ex`): não assina `RunnerStatus` e **não mostra
    em lugar nenhum** que o runner da tarefa está offline. Quem abre uma tarefa parada
    não vê o motivo. É o "runner offline na tarefa" que o enunciado cita: corrigimos
    aqui com o mesmo mecanismo (detalhes abaixo).

### O que muda para quem usa

- No Board, o card "Precisa de atenção" acompanha o runner ao vivo: o alerta "está
  parada: o runner X está offline" aparece quando o runner cai e some quando ele volta.
  O alerta "perto do limite" aparece assim que a execução reporta um `rate_limit` em 80%
  ou mais, e some sozinho na hora de renovação (`resets_at`) ou quando um novo
  `rate_limit` mostra a conta abaixo do limite.
- Na tela da tarefa (`TaskLive.Show`), uma tarefa em execução cujo runner está offline
  mostra um aviso, também ao vivo.

### Critérios de aceite verificáveis

1. Teste de LiveView no Board, sem novo `mount`: com uma tarefa `:running` e o runner
   rastreado em `RunnerStatus` por um processo, o alerta `board-alert-offline-<task.id>`
   não aparece. Ao matar o processo, ele aparece. Ao rastrear o runner de novo, ele some.
2. Teste de LiveView no Board: com a view aberta, `Runners.record_rate_limit/2` com
   utilização acima de 0,8 seguido de `RunnerStatus.notify_changed/1` (o caminho real do
   `RunnerChannel`) faz `board-alert-limit-<task.id>` aparecer.
3. Teste de LiveView: um `rate_limit` com `resets_at` próximo faz o alerta aparecer e
   depois sumir sozinho, sem evento novo.
4. Teste de LiveView em `TaskLive.Show`: o aviso `task-runner-offline` aparece e some
   com a presença do runner.
5. Spec e2e: tarefa com prompt `[lento] [limite]` rodando no runner real, Board aberto.
   O alerta de limite aparece. O runner é parado (`RunnerProcess.stop()`) e
   `board-alert-offline-<id>` aparece sem `page.reload()`.
6. `make ci` e `make e2e` verdes.

## Mudanças por app

### `apps/pipe_maestro` (domínio)

Sem schema e sem migração. Em `PipeMaestro.Tasks`:

- **`Tasks.runner_offline?(task, online_runner_ids) :: boolean()`** (pública, com
  `@spec` e `@doc`): a regra que hoje está inline em `alerts/2` (`status == :running` e
  `runner_id` fora do conjunto). `alerts/2` passa a usá-la, e `TaskLive.Show` também. A
  regra fica no domínio e a LiveView continua magra.
- **`Tasks.alerts_change_at(alerts, now \\ DateTime.utc_now()) :: DateTime.t() | nil`**:
  o próximo instante em que um alerta vence por tempo, sem evento. É o menor
  `Runners.resets_at(runner.rate_limit["resets_at"])` futuro entre os
  `{:runner_near_limit, _, runner}`. `nil` se não houver. É isso que permite ao alerta
  "sumir sozinho quando o limite renova" com um único timer, sem polling.
  - Fora do escopo: o instante em que uma decisão **passa** a ficar atrasada
    (`decision_due_at` de tarefas ainda não atrasadas). Isso exigiria consultar tarefas
    fora de `alerts/2`, e a tarefa não pede. Fica registrado como possível evolução.
- `alerts/2` mantém assinatura e consulta. O `@doc` passa a citar `runner_offline?/2`.

`Runners`, `Jobs` e o schema `Runner` não mudam. `Jobs.append_event/3` já grava o
`rate_limit` antes de o canal notificar.

### `apps/pipe_maestro_web`

- **`BoardLive`**:
  - Extrair `load_alerts/1` de `load_tasks/1`. Ele faz a mesma chamada de
    `Tasks.alerts(workspace, RunnerStatus.online_ids(workspace.id))`, atribui `:alerts` e
    agenda o timer de expiração (abaixo). `load_tasks/1` chama `load_alerts/1`.
  - `presence_diff` → `load_runners/1 |> load_alerts/1`, sem o `load_tasks/1` completo.
    Uma queda de runner não muda lista, colunas nem estatísticas. Se o runner reiniciado
    falhar o job (`Jobs.reconcile/2`), chega `{:task_updated, _}` e aí sim `load_tasks/1`.
  - `:runners_changed` → `load_runners/1 |> load_alerts/1`.
  - Timer: `load_alerts/1` cancela a referência anterior (`Process.cancel_timer/1`,
    guardada em `assigns.alerts_timer`) e, se `Tasks.alerts_change_at/1` devolver um
    instante, agenda `Process.send_after(self(), :alerts_expired, ms)`. Um único timer
    vale para o instante conhecido. Um novo `handle_info(:alerts_expired, socket)` chama
    `load_alerts/1`. O `ms` é limitado a um teto (por exemplo, 24 h, porque
    `send_after` aceita até ~49 dias e `resets_at` pode estar longe, como no
    `fake_claude`, em 2100). Ao passar do teto, o timer recalcula e reagenda.
  - Sem catch-all de `handle_info`: cada mensagem tem cláusula própria.
  - Atualizar o `@moduledoc`: os alertas acompanham o estado dos runners.
- **`TaskLive.Show`**:
  - No `mount` conectado, `RunnerStatus.subscribe(workspace.id)`.
  - Assign `runner_offline` = `Tasks.runner_offline?(task, RunnerStatus.online_ids(ws))`,
    recalculado no mount, em `presence_diff`, em `:runners_changed` e em
    `{:task_updated, task}` (a tarefa pode deixar de estar `:running`).
  - `handle_info/2` explícitos para `%Broadcast{event: "presence_diff"}` e
    `:runners_changed`. Hoje a tela não os recebe, e sem cláusula a LiveView quebraria.
  - Render: `<.alert color="danger" with_icon data-testid="task-runner-offline">` perto
    do cabeçalho (linha ~475, onde aparece `runner:diretório`). Texto: "A tarefa está
    parada: o runner X está offline." Componente Petal `alert`, já usado em
    `decisions_live.ex` e `layouts.ex`. Conferir os attrs em `lib/petal_components/alert.ex`
    (`color`, `with_icon`, `rest`), como pede `docs/guias/ui-petal.md`.
- `RunnerStatus`, `RunnerChannel`, `TaskLive.Index`, `JobsLive`, `RunnersLive`,
  `RunnerLive` e `UsageLive`: **não mudam**. O `@moduledoc` de `RunnerStatus` ("make
  every open screen reload its runners") pode ganhar "e os alertas que dependem deles".
  É só documentação.

### `apps/pipe_maestro_protocol`

**Não muda.**

### `apps/pipe_maestro_runner`

**Não muda.** O `fake_claude` já tem `[lento]` (30 s) e `[limite]` (`rate_limit_event`
em 86%), o suficiente para o e2e.

## Fronteiras

- O domínio ganha só funções puras sobre `Task`/`Runner`/`MapSet`/`DateTime`. Ele não
  conhece PubSub de presença nem web. A presença continua no web (`RunnerStatus`,
  `RunnerPresence`) e chega ao domínio como `MapSet`, como hoje.
- O runner não é tocado e segue dependendo só de `protocol`.
- Nenhuma dependência nova entre apps.

## Protocolo

A mudança **não toca** `apps/pipe_maestro_protocol` nem o formato das mensagens do
Channel (`job:event`, `rate_limit` e o `phx_join` com `Hello` ficam como estão). Os
sinais usados (`presence_diff`, `:runners_changed`) são PubSub interno do control
plane. `docs/specs/protocolo-runner.md` não muda, a versão do protocolo não sobe e
runners antigos não são afetados: o que eles mandam hoje já dispara os sinais.

## Telas

- **Board** (`BoardLive`): sem mudança visual. Os `data-testid` existentes
  (`board-alert-offline-<task.id>`, `board-alert-limit-<task.id>` etc., em
  `alert_testid/1`) passam a aparecer e sumir ao vivo. Seguem o padrão de
  `e2e/README.md`: id por registro com a chave natural, aqui o id da tarefa, como já é
  hoje. Para o spec, se não existir: `board-alerts` no card "Precisa de atenção".
- **Tarefa** (`TaskLive.Show`): novo `<.alert>` Petal com `data-testid="task-runner-offline"`.
- **Playwright**: novo spec `e2e/tests/board-alerts.spec.ts` (seção "Tarefas e
  pipelines", cabeçalho `@flow` como os demais), reaproveitando `RunnerProcess`,
  `AppPage`, `PipelinesPage`, `TasksPage` e `RunnersPage`:
  1. operador cria workspace e membro; o membro aprova um runner (device flow) e o inicia;
  2. cria os pipelines prontos e uma tarefa "Prompt único" com prompt `... [lento] [limite]`;
  3. abre o Board e espera `board-alert-limit-<id>` (a conta em 86%);
  4. `runner.stop()` e espera `board-alert-offline-<id>` **sem reload**;
  5. abre a tarefa e confere `task-runner-offline`;
  6. `shot(page, "board-alertas")` para auditar claro e escuro em `make e2e.shots`.
  - Se `AppPage` ou `TasksPage` não tiverem helpers para os alertas, acrescentar métodos
    (`boardAlert(kind, taskId)`) que usem só `getByTestId`.
  - O id da tarefa vem da URL após a criação, como nos specs atuais.

## Testes

- **`apps/pipe_maestro/test/pipe_maestro/tasks_test.exs`**:
  - `runner_offline?/2`: `:running` com o runner fora e dentro do conjunto;
    `:awaiting_decision` nunca é offline.
  - `alerts_change_at/2`: `nil` sem alerta de limite; o menor `resets_at` futuro entre
    dois runners; ignora `resets_at` passado ou ausente.
  - `alerts/2` continua coberto pelos testes existentes.
- **`apps/pipe_maestro_web/test/pipe_maestro_web/live/board_live_test.exs`**, com o
  padrão de `runners_live_test.exs`: processo `tracker` + `RunnerStatus.track/2` +
  `Process.exit(tracker, :kill)` + `eventually/1`:
  - "o alerta de offline aparece e some com a presença do runner" (critério 1);
  - "o alerta de limite aparece quando um rate_limit é gravado" (critério 2), com
    `record_rate_limit` + `RunnerStatus.notify_changed/1`;
  - "o alerta de limite some quando o limite renova" (critério 3), com `resets_at`
    poucos segundos à frente, ou mandando `:alerts_expired` para `view.pid` depois de
    gravar um `resets_at` já vencido, para não depender de `sleep`;
  - os testes atuais de alertas no mount continuam.
- **`task_live_test.exs`**: aviso `task-runner-offline` aparece e some com a presença
  (critério 4), e não aparece numa tarefa `:awaiting_decision`.
- **e2e**: `board-alerts.spec.ts` (critério 5).
- Validar com `mix test` focado durante o trabalho e fechar com `make ci` e `make e2e`
  (critério 6), mais `make e2e.shots` para o novo aviso em `TaskLive.Show`.

## Documentação

- **ADR**: não precisa de uma nova. A decisão de mostrar esses alertas está nas ADRs
  0012 (item 5) e 0024 ("como alerta no Board"). A mudança só cumpre o "atualiza ao
  vivo" que já está no `@moduledoc` do Board. Uma linha na ADR 0024, no item do limite
  da conta, registra que o alerta some sozinho na renovação (timer até `resets_at`, sem
  polling).
- **Specs**: `docs/specs/protocolo-runner.md` e `maquina-de-estados-tarefa.md` não mudam.
- **Guias**: nenhum muda.
- `@moduledoc`/`@doc`: `BoardLive`, `RunnerStatus`, `Tasks.alerts/2` e as funções novas.

## Riscos

- **Migrações e dados**: nenhuma. `rate_limit` existente segue lido por
  `Runners.near_limit?/2`.
- **Concorrência**:
  - O `presence_diff` de uma queda pode chegar antes ou depois de um `{:task_updated, _}`
    vindo de `Jobs.reconcile/2` na reconexão. Os dois recalculam a partir do banco e da
    presença atuais, então a ordem não importa.
  - No `rate_limit`, o canal notifica depois de `append_event/3` retornar, que já gravou
    o runner. Não há leitura antes da escrita.
- **Timers**: cancelar o anterior em cada `load_alerts/1` evita acumular timers. Limitar
  o `ms` evita estourar o `send_after` com `resets_at` distante.
- **Custo**: `:runners_changed` também chega em `worktree:usage` e `runner:directories`.
  Cada um passa a rodar a consulta de `alerts/2`, que é uma só, com preload de runner.
  Ainda assim fica mais barato que hoje no `presence_diff`, que deixa de chamar
  `load_tasks/1`. Aceitável, sem polling.
- **Testes instáveis**: a presença é assíncrona. Usar `eventually/1`, que já existe nos
  testes, e nunca `Process.sleep`.
- **e2e**:
  - `[lento]` dá 30 s. Os alertas devem aparecer bem antes disso; o timeout do spec
    segue os 240 s dos specs com runner real.
  - Parar o runner com o job ativo deixa o `fake_claude` órfão: conferir que
    `RunnerProcess.cleanup()` resolve, como em `job-execution.spec.ts`.
- **Cobertura e Dialyzer**: funções novas com `@spec` exatos (`DateTime.t() | nil`,
  `boolean()`). O `alerts_timer` no assign é `reference() | nil`. As cláusulas novas de
  `handle_info` ficam cobertas pelos testes acima.
