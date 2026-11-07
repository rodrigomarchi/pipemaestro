# Implementação — board do workspace em abas

## O que mudou, por app

### `apps/pipe_maestro_web`

- `lib/pipe_maestro_web/live/board_live.ex`: a LiveView ficou fina. Ela navega pelas abas com `?aba=`
  (`visao` é a padrão, e um valor desconhecido cai nela) e lê os filtros do kanban da URL em
  `handle_params/3` (`pipeline`, `runner_id`, `project_id`, `user_id`, só os não vazios). O
  `phx-change="filter"` faz `push_patch` para `/w/:slug?aba=tarefas&…`.
  - A barra é feita com `<.tabs variant="underline">` e `<.tab link_type="live_patch">` do Petal,
    com os testids `board-tabs` e `board-tab-<id>`. A aba ativa é marcada por `aria-selected`.
  - Os contadores são `<.badge data-testid="board-tab-count-<id>">`:
    - `visao`: número de alertas, só quando > 0, em vermelho;
    - `decisoes`: valor de `@pending_decisions`, mantido ao vivo pelo hook de `UserAuth`, só quando > 0;
    - `executores`: `online/total`, sempre visível.
  - Runners e alertas são carregados em todo `handle_params` e em todo evento, para os contadores
    ficarem certos qualquer que seja a aba aberta. Os dados próprios de cada aba vêm de `load_tab/1`.
  - Eventos ao vivo:
    - presença e `:runners_changed` recarregam runners e alertas;
    - `{:task_updated, _}` recarrega alertas e a aba aberta;
    - `{:job_updated, _}` recarrega só a Visão geral, a única que mostra o custo;
    - `:alerts_expired` mantém o timer como antes.
  - Toda mensagem assinada tem uma cláusula explícita.
- Módulos novos em `lib/pipe_maestro_web/live/board_live/`, todos com `@moduledoc` e com `@spec` em
  toda função pública:
  - `OverviewTab`: `load/2` traz os stats, as 3 próximas decisões e as 5 últimas atividades. Mostra
    o card "Precisa de atenção" (com `alert_line` e `alert_testid`, vindos da antiga `BoardLive`),
    os 4 stat cards e os resumos, com "Ver tudo" (`live_patch`). Testids: `board-overview-decisions`,
    `board-overview-decision-<id>`, `board-overview-no-decisions`, `board-overview-decisions-all`,
    `board-overview-activity` e `board-overview-activity-all`.
  - `TasksTab`: `filter_keys/0`, `load/2` e `stage_label/1`. Essa função ficou aqui e não em
    `TaskComponents`, porque lá já existe um `stage_label/1` privado com outro sentido. O módulo
    renderiza o kanban, o form `#board-filters` (preenchido a partir da URL) e as colunas.
  - `DecisionsTab`: `load/1`, `decisions/1` e `decision_list/1`. A lista é reaproveitada no resumo,
    com outro prefixo de testid.
  - `ActivityTab`: `load/2` (20 itens por padrão), `activity/1` e `activity_list/1`. A lista também é
    reaproveitada no resumo.
  - `RunnersTab`: `runners/1`, com a tabela de runners.
- Os testids existentes foram mantidos, cada um na sua aba.

### `apps/pipe_maestro`, `apps/pipe_maestro_protocol`, `apps/pipe_maestro_runner`

Não mudaram. O protocolo não foi tocado, então não há tratamento de runner antigo a fazer.

## Testes corrigidos, e por quê

Em `test/pipe_maestro_web/live/board_live_test.exs`:

1. **`the counters on the tabs follow the workspace live, whatever tab is open`**: o teste esperava
   o contador da Visão geral em `1` (alerta de runner offline) depois de derrubar o runner. Só que a
   única tarefa criada nele estava em `awaiting_decision`, e `Tasks.runner_offline?/2` só alerta
   tarefas `:running`, que é a regra de domínio. Acrescentei uma tarefa que continua em execução
   ("Fica rodando") antes de derrubar o runner, com `refute` do contador enquanto ele está online. A
   afirmação original continua a mesma.
2. **`the filters come from the URL…`**: o seletor `option[value=<uuid>]` sem aspas é CSS inválido
   quando o UUID começa com dígito (LazyHTML lança `invalid css selector`), e por isso o teste falhava
   de forma intermitente. Agora ele usa `option[value="<uuid>"]`.

Em `e2e/tests/task-pipeline.spec.ts`: removi uma linha `@flow K [todo]` duplicada. Ela repetia o
flow N, e a letra K já pertence a outro flow. O flow N foi marcado como `[done]`.

## Como verificar

- `cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/live/board_live_test.exs test/pipe_maestro_web/live/work_by_project_live_test.exs`
  → 37 testes passam, estáveis em 6 rodadas seguidas.
- Suíte do app web: 370 testes passam.
- `make ci.quick > /tmp/ciq.log 2>&1; echo $?` → `0`.
- `mix dialyzer` → 0 erros.
- `make e2e.shots` → 28/28 passam.
- Screenshots conferidos em `e2e/screenshots/task-pipeline/…/22-board-visao` até
  `27-board-tabs-narrow`, nos temas claro e escuro. A barra de abas rola na horizontal em 390 px.
