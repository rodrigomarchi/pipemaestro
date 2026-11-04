# 03 — Implementação: linha do tempo compacta com ícones dos eventos

Os testes da etapa 2 passam sem nenhuma mudança neles. O protocolo, o domínio e o banco
não mudaram.

## O que mudou, arquivo por arquivo

### `apps/claude_control_plane_web/lib/claude_control_plane_web/components/job_components.ex`

- **Funções puras novas** (todas com `@spec` e `@doc`):
  - `icon?/1`: tudo vira ícone, menos `assistant_text` e `result`.
  - `event_state/1`: `:denied` para `permission_denied` e decisão `reject`; `:error` para
    `api_retry` e `is_error`; `:normal` para o resto.
  - `event_summary/1`: o resumo de uma linha que vai no tooltip e no `aria-label`.
    Ferramenta: nome e detalhe (descrição ou comando no Bash, caminho no Read/Edit/Write,
    padrão no Grep/Glob, senão o `text`), cortado por `prompt_summary/2`. Resultado:
    `Saída · N linhas`, `Erro · N linhas`, `Negada (fonte)` ou `Sem saída`. Pensamento,
    sessão (com `auth_label/1`), limites, compactação, negação e retry. Depois vêm os
    tokens do turno (`tokens_label/1`) e `subagente`.
  - `timeline_items/2`: agora devolve segmentos `%{id, kind: :strip | :text, events}`.
    Aplica o filtro, depois faz um `reduce` com `timeline_push/2`. Assim a lista inteira
    e o ao vivo seguem a mesma regra. O filtro entra no id da faixa
    (`strip-<filtro>-<event.id>`).
  - `timeline_tail/1`: a cauda lida no mount (a última faixa, se houver, e os `seq` já
    mostrados).
  - `timeline_push/2`: um evento ao vivo. Um ícone com faixa aberta entra nessa faixa,
    que mantém o id. Um ícone sem faixa aberta abre uma faixa nova. Texto vira um bloco
    e fecha a faixa. Um `seq` já visto devolve `:seen`.
  - Tipos `segment` e `tail` (a cauda guarda também o filtro que nomeia as faixas novas).
- **Componentes:**
  - `timeline/1` (público): um `<ol id>` com os segmentos. Recebe `class` e attrs globais.
  - `timeline_segment/1` (público): usado também no `:for` dos streams. Uma faixa
    (`job-event-strip-<seq>`) tem os ícones em `flex flex-wrap`, com todos os painéis
    renderizados escondidos logo abaixo. Um bloco de texto (`job-event-<seq>`) mantém o
    visual de antes, inclusive o `ml-8` de subagente.
  - `event_icon/1` (privado): `<.icon_button>` do Petal, `size="xs"`, cor `gray` ou
    `danger` por estado, `tooltip` com o resumo, `aria-label`, `aria-expanded`,
    `aria-controls`, `data-type`, `data-state`, `data-subagent` (contorno tracejado) e
    `data-event-icon`. O `phx-click` é `toggle_panel/3`, feito com `Phoenix.LiveView.JS`:
    esconde os outros painéis da mesma linha do tempo, tira o anel e o `aria-expanded`
    dos outros ícones e alterna o painel, o anel e o `aria-expanded` do ícone clicado.
    Como as operações de `JS` são sticky, o painel continua aberto quando a faixa recebe
    patch.
  - `event_panel/1` e `event_header/1` (privados): o cabeçalho de antes (rótulo, nome,
    subagente, tokens, negação) e `event_body/1`.
  - Os ids de DOM de ícone e painel derivam do id do segmento (que contém o filtro), por
    isso duas linhas do tempo na mesma página não colidem.
- **`event_body/1`:** o pensamento e a saída da ferramenta deixaram de usar `<details>`,
    porque o painel já é a abertura. Saída vazia mostra "Sem saída.". O conteúdo do Write
    continua recolhido. Os limites reaproveitam `utilization_labels/1`, a mesma usada no
    resumo.
- **`event_look/1`:** o `result` ganhou uma cláusula própria ("Fim da execução"). Um tipo
  desconhecido usa o ícone genérico `hero-ellipsis-horizontal-circle`, rotulado pelo
  próprio tipo.
- **Saiu:** `job_event/1` e o agrupamento de leituras (`reading?`, `answers_read?`,
  `flush`, `reading_label`, `{:group, …}`, `job-event-group`). `count_label/3` ficou,
  porque `AuditComponents` usa.
- `steps/1` agora é um `timeline/1` com id `steps-<chave>-<tentativa>` e o mesmo
  `data-testid="stage-run-steps-…"`.
- `import PetalComponents.Timeline, only: []`: o Petal também tem `timeline/1`, e o
  import dele colidia com o componente local.
- O `@moduledoc` agora descreve as faixas, os blocos e os painéis abertos por `JS`.

### `apps/claude_control_plane_web/lib/claude_control_plane_web/live/job_live.ex`

- O mount faz `stream(:timeline, timeline_items(events, "all"))` e
  `assign(timeline_tail: timeline_tail(segments))`.
- `handle_info({:job_event, e})` chama `timeline_push/2`. Com `:seen` não faz nada
  (descarta a duplicata da janela entre `subscribe` e `list_events`). Nos outros casos
  faz `stream_insert(:timeline, segment)`, com o mesmo id quando a faixa cresce, e
  atualiza a cauda, o `event_count` e o `typing`.
- `#job-events` desenha `<.timeline_segment … timeline="job-events">`.
- O `@moduledoc` e o comentário do mount foram atualizados.

### `apps/claude_control_plane_web/lib/claude_control_plane_web/live/task_live/show.ex`

- `follow_running_job/1` usa `live_timeline/2`, que monta o stream `:timeline` (com
  `reset: true`) e a cauda do job que está rodando, ou os dois vazios.
- `handle_info({:job_event, e})`: igual ao `JobLive`, só para `live_job_id`.
- `#task-events` desenha `timeline_segment` com `timeline="task-events"`.
- Os imports foram atualizados (sai `job_event: 1`; entram `timeline_push`,
  `timeline_segment` e `timeline_tail`), e o `@moduledoc` também. O passo a passo
  terminado continua com `timeline_items(@steps, @steps_filter)`.

### `apps/claude_control_plane_runner/test/support/fake_claude` (só teste)

- Marcador novo `[gotejando]`: depois do primeiro `tool_result`, espera 3 s e emite
  mais um `tool_use` Bash (`msg_3`) e o resultado dele. O cabeçalho do script documenta
  o marcador. `[lento]` não mudou.

### e2e

- `e2e/pages/JobsPage.ts`: classe `Timeline` nova, com escopo num contêiner, e os
  métodos `icons()`, `texts()`, `strip(seq)`, `icon(seq)`, `panel(seq)`, `text(seq)` e
  `toggle(seq)`. `JobsPage.events` saiu e `JobsPage.timeline` entrou.
- `e2e/pages/TasksPage.ts`: `openSteps(key, attempt)` e `filterSteps(key, attempt, filter)`.
- `e2e/tests/job-execution.spec.ts`:
  - Fluxo A: 4 ícones numa faixa só, 2 blocos, `data-state="normal"`, painéis
    escondidos. Clicar abre o painel 3 (com o caminho do Write e
    `aria-expanded="true"`), clicar em outro ícone troca e clicar de novo fecha.
    Capturas a 800 px.
  - Fluxo D novo (`[gotejando]`): o painel do pensamento é aberto, o ícone 5 chega
    na faixa 1, e o painel continua aberto até o job terminar.
  - Fluxo B: `icons()` com 4 em vez de `toHaveCount(4)` nos eventos.
- `e2e/tests/task-pipeline.spec.ts`, fluxo H novo: o passo a passo de `triagem-1`
  abre, troca e fecha painéis. O filtro "Raciocínio" deixa uma lâmpada só, sem blocos,
  e ela abre o painel "não mostra o raciocínio".

## Saída dos testes

Os testes da etapa 2:

```
mix test apps/claude_control_plane_web/test/claude_control_plane_web/components/job_components_test.exs \
         apps/claude_control_plane_web/test/claude_control_plane_web/live/job_live_test.exs \
         apps/claude_control_plane_web/test/claude_control_plane_web/live/task_live_test.exs

Finished in 1.5 seconds (0.2s async, 1.3s sync)
Result: 59 passed
```

`make ci` (exit 0):

```
mix credo --strict … 1847 mods/funs, found no issues.
Result: 40 passed                        (protocol)
Result: 149 passed (1 doctest, 148 tests)
Result: 202 passed
Result: 105 passed
mix dialyzer … Total errors: 0, Skipped: 0, Unnecessary Skips: 0
done (passed successfully)
```

`make e2e FILE="tests/job-execution.spec.ts tests/task-pipeline.spec.ts"`:

```
✓ tests/job-execution.spec.ts › Job execution › runs, cancels and fails jobs on a real runner (14.5s)
✓ tests/task-pipeline.spec.ts › Task pipeline › runs a task through the pipeline's stages on a real runner (13.9s)
2 passed (32.2s)
```

`make e2e.shots` das mesmas specs (claro e escuro) passou. As capturas revisadas foram
`job-event-panel-open`, `job-timeline-narrow`, `job-event-panel-open-live`,
`task-steps-panel-open` e `task-steps-thinking`. Nas duas variantes, os ícones aparecem
lado a lado com contraste, o ícone aberto tem anel e o painel fica abaixo da faixa em
largura total. Ao vivo, a faixa ganhou os ícones do Bash e o painel do pensamento
continuou aberto. O tooltip aparece acima do ícone sem corte no card. Nas capturas
recortadas no contêiner, o topo do tooltip e o anel do primeiro ícone ficam na borda do
recorte, e isso vem do enquadramento, não da página.

## Pendências e observações

- **Largura de 800 px:** na captura `04-job-timeline-narrow`, os cards da página do job
  passam da largura da janela (a barra do topo acaba em 800 px e os cards vão até
  ~950 px). A linha do tempo cabe. A suspeita é a tabela de ferramentas da auditoria,
  que tem seis colunas e divide a coluna com os outros cards, mas isso não foi
  confirmado nesta etapa. Vale conferir na revisão.
- **Documentação** (ADR 0016, índice do `docs/README.md`, roadmap): ficou para a etapa
  de documentação, como no plano (§4).
- Os attrs do `icon_button`/tooltip do Petal 4.17.1 foram conferidos no pacote extraído
  em `tmp/petal` (diretório ignorado pelo git).
