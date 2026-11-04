# 02 — Testes que falham: linha do tempo compacta com ícones dos eventos

Nenhum código de produção mudou nesta etapa. Os testes compilam contra o
`JobComponents` atual e falham porque as funções e o markup novos ainda não existem.

## Testes criados ou alterados

Todos em `apps/pipe_maestro_web/test/pipe_maestro_web/`.

### `components/job_components_test.exs` (reescrito)

O teste antigo renderizava `job_event/1` e esperava `{:event, _}` / `{:group, …}`. Agora:

| `describe` | O que prova | Crit. |
|---|---|---|
| which events become icons | `icon?/1`: verdadeiro para `system thinking tool_use tool_result rate_limit api_retry compact permission_denied` e um tipo desconhecido; falso para `assistant_text` e `result`. `event_state/1`: erro de ferramenta e `api_retry` → `:error`; `permission_denied` e `decision.decision == "reject"` (em `tool_use` e `tool_result`) → `:denied`; o resto → `:normal` | 1, 2, 3 |
| the one-line summary of an icon | `event_summary/1`: `"Bash · Roda a suíte"`, `"Bash · mix test"` (primeira linha), comando longo cortado com `…`, `"Read · /w/lib/a.ex"`, Edit/Write pelo caminho, Grep/Glob pelo padrão, ferramenta desconhecida pelo `text`; `"Saída · 3 linhas"`, `"Erro · 1 linha"`, `"Negada (config)"`; `"Pensou por 1 s"`; `"Sessão iniciada (haiku) · login pessoal"` / `· chave de API`; `"allowed · five_hour 20%"`; `"… · tinha 150.0k tokens"`; texto do retry; negação com ferramenta e texto; `· subagente` no fim; tokens do turno | 2 |
| segments | `timeline_items/2` devolve `%{id, kind: :strip \| :text, events}`: `[strip-all-1 (1..7), text-8, strip-all-9 (9..11), text-12]`; o filtro entra no id (`strip-agent-1`, `strip-tools-2`, `strip-thinking-11`); "Raciocínio" dá uma faixa só de pensamentos; "Erros" uma faixa de retry e negação; lista vazia → `[]` | 1, 3, 6 |
| a live run | `timeline_tail/1` e `timeline_push/2`: ícone com faixa aberta → mesmo id com o evento no fim; texto → bloco e `tail.strip == nil`; ícone depois de texto → faixa nova; `seq` já visto → `{:seen, tail}`; a cauda lida no mount continua a última faixa; `timeline_items` é o `reduce` de `timeline_push` | 5 |
| a strip of icons | `timeline/1` (`id`, `segments`): `job-event-strip-<seq>` com um `button[data-testid=job-event-icon-<seq>]` por evento, `data-type`, `data-state`, `aria-label="Ferramenta: Bash · Roda a suíte"`, `aria-expanded="false"`, o resumo no HTML da faixa (tooltip), classe `danger` só nos de erro/negado; `job-event-panel-<seq>` dentro da faixa, `hidden`, com `data-type`; o `phx-click` do ícone contém o id do painel e o da linha do tempo; duas linhas do tempo com ids de painel diferentes; tipo desconhecido rotulado pelo tipo (não "Fim da execução"); ícone de subagente com `data-subagent` | 1, 2, 4 |
| a panel shows the event in full | O conteúdo de hoje, agora dentro do painel: sessão, `$ mix test`, diff do Edit, Write recolhido em `<details>`, Read/Grep, TodoWrite, ferramenta desconhecida; saída **aberta** (sem `<details>`), erro aberto no painel com "Erro da ferramenta", saída vazia → "Sem saída."; "negada (config)"; pensamento aberto e "não mostra"; retry, compactação, negação, limites; tokens | 4 |
| a text block | `job-event-<seq>[data-type=…]`: Markdown e tokens da resposta, tokens do resultado, subagente com `ml-8` | 3 |
| (solto) | `steps/1` desenha faixas e blocos, sem `job-event-group` nem "Leu 2 arquivos" | 6 |

### `live/job_live_test.exs`

- Teste novo **"icons join the strip read on mount; text closes it; a repeated event
  shows once"**: texto e pensamento antes do mount (`job-event-1` e
  `job-event-strip-2`); um `tool_use` ao vivo entra na mesma faixa (ícone e painel com
  "ls") e só há uma faixa; o mesmo evento reenviado (`send(view.pid, {:job_event, …})`,
  a janela entre `subscribe` e `list_events`) não duplica o ícone; texto ao vivo vira
  bloco e o ícone seguinte abre `job-event-strip-5`; "5 eventos".
- **"shows the run growing live until it ends"** adaptado: `job-event-icon-2`
  (`tool_use`, `normal`) e `job-event-icon-3` (`tool_result`, `error`) na
  `job-event-strip-1`, painéis com "Write" e "Erro da ferramenta", blocos
  `job-event-4` (`assistant_text`) e `job-event-5` (`result`).

### `live/task_live_test.exs`

- Teste novo **"the running stage's icons grow a strip; the finished steps filter it"**:
  na etapa rodando (`stage-a` → `task-events`), pensamento e Bash ao vivo entram em
  `job-event-strip-2` (painel com `$ mix test`); terminada a etapa, o passo a passo tem o
  bloco `job-event-1` e a faixa; o filtro "Raciocínio"
  (`stage-run-steps-filter-a-1-thinking`) mostra só o ícone de pensamento, com o painel
  "Olhar o form"; "Ferramentas" mostra só o Bash.
- O teste "follows the stages live…" continua como está (o texto "trabalhando" é um bloco
  de texto e continua visível pelos mesmos seletores de contêiner).

### Fora do ExUnit

Abrir, fechar e trocar o painel (JS no cliente) e o painel que continua aberto quando a
faixa cresce ao vivo são provados no e2e (`job-execution.spec.ts`,
`task-pipeline.spec.ts`), escritos junto com a implementação, como no plano (§3, D1).

## Comando

Da raiz do umbrella (o `mix test` com caminhos roda só esses arquivos no app web):

```
mix test apps/pipe_maestro_web/test/pipe_maestro_web/components/job_components_test.exs \
         apps/pipe_maestro_web/test/pipe_maestro_web/live/job_live_test.exs \
         apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs
```

## Saída (resumida)

```
Finished in 1.5 seconds (0.3s async, 1.2s sync)
Result: 22/59 passed
Failed: 37 tests
```

As 37 falhas, por motivo:

- **Funções que ainda não existem** (`UndefinedFunctionError`), em 30 testes do
  `JobComponentsTest`:
  ```
  ** (UndefinedFunctionError) function PipeMaestroWeb.JobComponents.timeline/1 is undefined or private
  ** (UndefinedFunctionError) function PipeMaestroWeb.JobComponents.icon?/1 is undefined or private
  ** (UndefinedFunctionError) function PipeMaestroWeb.JobComponents.event_state/1 is undefined or private
  ** (UndefinedFunctionError) function PipeMaestroWeb.JobComponents.event_summary/1 is undefined or private
  ** (UndefinedFunctionError) function PipeMaestroWeb.JobComponents.timeline_tail/1 is undefined or private
  ```
- **Formato antigo de `timeline_items/2`** (3 testes de "segments"): `match (=) failed`
  com o lado direito ainda em `{:event, %Event{}}` / `{:group, "Leu 2 arquivos e fez 1
  busca", […]}`.
- **`steps/1` sem faixas**: `assert … LazyHTML.query("[data-testid=job-event-strip-1]") |> Enum.count() == 1` → `left: 0`.
- **LiveViews ainda com um `<li data-testid="job-event">` por evento** (3 testes):
  ```
  Expected truthy, got false
  code: assert has_element?(view, "[data-testid=job-events] [data-testid=job-event-1]", "Vou ver")

  Expected truthy, got false
  code: assert has_element?(view, "#{strip(1)}[data-testid=job-event-icon-2][data-type=tool_use][data-state=normal]")

  Expected truthy, got false
  code: assert has_element?(view, "[data-testid=stage-a] [data-testid=task-events] [data-testid=job-event-strip-2] [data-testid=job-event-icon-2][data-type=thinking]")
  ```

Nenhuma falha é de sintaxe, de setup ou de seletor inválido. Os 22 testes que passam são
os do `TaskLiveTest` e `JobLiveTest` que não tocam a linha do tempo.

A compilação dos testes avisa que `icon?/1`, `event_state/1`, `event_summary/1`,
`timeline/1`, `timeline_tail/1` e `timeline_push/2` não existem. É esperado nesta etapa e
some com a implementação. Até lá, `make ci` (`--warnings-as-errors`) não passa.
