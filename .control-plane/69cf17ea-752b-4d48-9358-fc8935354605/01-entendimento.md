# 01 — Entendimento e plano: linha do tempo compacta com ícones dos eventos

## 0. Onde está hoje

- `ClaudeControlPlaneWeb.JobComponents` (`apps/claude_control_plane_web/lib/claude_control_plane_web/components/job_components.ex`):
  - `job_event/1` desenha cada evento como um `<li>` inteiro: bolha com ícone, rótulo e
    corpo (`event_body/1`, `tool_body/1`). O visual de cada tipo vem de `event_look/1`.
  - `timeline_items/2` filtra (`all | agent | tools | thinking | errors`) e junta duas ou
    mais leituras e buscas seguidas num `{:group, "Leu 2 arquivos…", events}`.
  - `steps/1` desenha os itens de `timeline_items/2` (o passo a passo de uma tentativa
    terminada) e usa `data-testid="job-event-group"` para os grupos.
- Há três lugares que mostram eventos:
  1. `JobLive` (`live/job_live.ex`): `stream(:events, …)` + `stream_insert` a cada
     `{:job_event, event}`, sem filtro. Conta os eventos pelo maior `seq`.
  2. `TaskLive.Show`, etapa rodando agora: `stream(:events, …)` em `#task-events`, sem
     filtro.
  3. `TaskLive.Show`, tentativa terminada: `timeline_items(@steps, @steps_filter)` com os
     botões de filtro `stage-run-steps-filter-<chave>-<tentativa>-<filtro>`. É o único
     lugar com filtro.
- O domínio entrega `Jobs.list_events/1` (ordenado por `seq`) e publica cada evento novo
  uma vez (`append_event/3` com `on_conflict: :nothing` não republica duplicatas). Nada
  disso muda.
- Versões: `phoenix_live_view` 1.2.13 e `petal_components` 4.17.1. O Petal 4.17 tem
  `<.tooltip>` (só CSS, hover e foco, `role="tooltip"`) e `<.icon_button>` com os attrs
  `size`, `color` (`gray`, `danger`…), `radius`, `tooltip` e globais. Os dois servem aqui.

## 1. Especificação

### O que muda para quem usa

A linha do tempo passa a ser uma sequência de **segmentos**, de dois tipos:

- **Faixa de ícones**: os eventos sem texto para ler, seguidos, viram ícones pequenos lado
  a lado numa linha que quebra quando enche (`flex flex-wrap`). São eles:
  `system` (sessão), `thinking`, `tool_use`, `tool_result`, `rate_limit`, `api_retry`,
  `compact` e `permission_denied`. Um tipo desconhecido também vira ícone, com o ícone
  genérico e o próprio tipo como rótulo.
- **Bloco de texto**: `assistant_text` e `result` continuam como hoje (ícone, cabeçalho
  com tokens, Markdown/texto), em largura total. Um bloco de texto interrompe a faixa:
  os ícones depois dele começam uma faixa nova.

Cada ícone:

- é um botão (`<.icon_button>` do Petal, `size="xs"`), com o glifo de hoje
  (`event_look/1`): lâmpada para pensamento, chave para ferramenta, seta para resultado,
  `play` para sessão, gráfico para limites, `arrow-path` para retry, caixa para
  compactação, `no-symbol` para negação, triângulo para erro de ferramenta;
- tem **cor por estado**, com três estados:
  - `normal` → cinza;
  - `error` → vermelho: `tool_result` com `is_error`, `api_retry`;
  - `denied` → vermelho: `permission_denied`, e um `tool_use`/`tool_result` cuja
    `decision.decision` é `"reject"`.
  Erro e negação se distinguem pelo glifo e pelo texto do tooltip, não pela cor;
- tem **tooltip** (o do Petal) com o resumo de uma linha:
  - ferramenta: nome e o que ela faz: Bash → descrição, ou a primeira linha do comando;
    Read/Edit/Write → o caminho; Grep/Glob → o padrão; outras → o `text` do evento;
    corta em ~80 caracteres (`prompt_summary/2` já faz isso);
  - resultado: "Saída · 12 linhas", "Erro · 3 linhas", ou "Negada (config)";
  - pensamento: "Pensou por 1 s";
  - sessão: o texto ("Sessão iniciada (haiku)") · login pessoal / chave de API;
  - limites: status e janelas ("allowed · five_hour 20%");
  - retry, compactação, negação: o texto do evento (compactação com "tinha 150.0k tokens";
    negação com o nome da ferramenta);
  - um evento de subagente acrescenta "· subagente"; o primeiro evento de um turno
    acrescenta os tokens ("12.3k → 678 tokens");
- tem `aria-label` = rótulo do tipo + o mesmo resumo ("Ferramenta: Bash · Roda a suíte"),
  e `aria-expanded` que acompanha o painel;
- um ícone de subagente fica com um contorno tracejado (e `data-subagent`), para não
  perder a informação que hoje é o recuo `ml-8`.

**Painel.** Clicar num ícone abre, logo abaixo da faixa a que ele pertence, um painel de
largura total com o conteúdo completo de hoje (o cabeçalho com rótulo, nome, subagente,
tokens e negação, e o corpo de `event_body/1`: comando, diff do Edit, conteúdo do Write,
TodoWrite, argumentos, saída, pensamento). Dentro do painel, a saída e o pensamento já
vêm abertos (o clique foi a abertura); o conteúdo do Write continua recolhido.

- Clicar no mesmo ícone fecha o painel.
- Clicar em outro ícone da mesma linha do tempo troca o painel (fecha o aberto, abre o
  novo), mesmo que o outro ícone esteja noutra faixa.
- O ícone aberto fica destacado (anel) e com `aria-expanded="true"`.
- Erros e negações não abrem sozinhos: ficam como ícone vermelho e abrem no clique (hoje
  a saída de erro vem aberta; isso deixa de valer).

**Ao vivo.** Na página do job e na etapa rodando da tarefa, um evento novo:

- de ícone, quando o último segmento é uma faixa: entra no fim dessa faixa;
- de ícone, quando o último segmento é um bloco de texto (ou não há segmentos): abre uma
  faixa nova;
- de texto: vira um bloco novo no fim.

O painel que estiver aberto **continua aberto** quando a faixa dele recebe um ícone novo,
e quando chegam segmentos novos depois dela. O indicador "escrevendo…" (`typing/1`)
continua abaixo de tudo.

**Filtro.** O passo a passo de uma tentativa terminada mantém os filtros Tudo, Agente,
Ferramentas, Raciocínio e Erros, aplicados antes do agrupamento em faixas:

- "Raciocínio" mostra uma faixa só de lâmpadas; cada uma abre o pensamento;
- "Erros" mostra faixas de ícones vermelhos (erros de ferramenta, retries, negações);
- "Agente" mostra a sessão como ícone e as respostas e o resultado como blocos;
- trocar o filtro fecha o painel aberto (os segmentos são outros).

**O agrupamento "Leu 2 arquivos e fez 1 busca" sai.** Ele existia para economizar
linhas; com leituras e buscas viradas ícones, a faixa já faz isso, e um `<details>`
dentro da faixa seria um segundo jeito de abrir a mesma coisa. O resumo de leitura fica
no tooltip de cada ícone.

### Casos de borda

- Linha do tempo vazia: a mensagem de hoje (`job-no-events`) não muda.
- Uma execução só de ícones (cancelada antes da resposta, ou o filtro "Raciocínio"): uma
  faixa só, sem bloco.
- Faixa muito longa (centenas de chamadas): quebra em várias linhas; a faixa é um
  segmento só, e o painel aparece abaixo dela inteira. É a contrapartida de "abaixo da
  faixa" (ver Riscos).
- Evento lido no mount e também recebido pela assinatura (a janela entre `subscribe` e
  `list_events`): aparece uma vez só.
- Evento atrasado (seq menor que o último mostrado, só depois de uma reconexão do
  runner): entra no fim, como hoje com o stream.
- `tool_result` sem texto: vira ícone; o painel diz "Sem saída.".
- `thinking` sem texto: o painel diz o que diz hoje ("O CLI não mostra o raciocínio…").
- Largura estreita (~800 px): a faixa quebra; o tooltip não pode ser cortado pela borda do
  card (placement e `overflow` conferidos nas capturas).
- Duas linhas do tempo na mesma página (a etapa ao vivo e o passo a passo de uma
  tentativa terminada, ou duas tentativas abertas): cada uma tem o seu painel; abrir um
  numa não fecha o da outra.
- Teclado: o ícone é um `<button>`; Tab chega nele, o foco mostra o tooltip (`focus-within`)
  e Enter/Espaço abre o painel.

### Critérios de aceite

1. Sessão, pensamento, chamada de ferramenta, resultado, limites, retry, compactação e
   negação aparecem como ícones lado a lado; ícones seguidos ficam na mesma faixa, que
   quebra de linha quando enche.
2. Cada ícone tem tooltip com o resumo, `aria-label` e cor por estado (normal cinza; erro
   e negado vermelhos), com `data-state` = `normal | error | denied`.
3. `assistant_text` e `result` aparecem em largura total como hoje e interrompem a faixa.
4. Clicar num ícone abre o painel com o conteúdo completo abaixo da faixa; clicar de novo
   fecha; clicar em outro troca.
5. Na página do job e na etapa ao vivo da tarefa, eventos novos entram na faixa e o
   painel aberto continua aberto.
6. Os filtros do passo a passo continuam funcionando, inclusive "Raciocínio".
7. Nada muda no protocolo, no domínio nem no banco.
8. `make ci` e `make e2e` passam; as capturas claro/escuro, inclusive a ~800 px, não
   mostram corte, sobreposição nem ícone sem contraste.

## 2. Plano

### Apps tocados

| App | Muda? | O quê |
|---|---|---|
| `claude_control_plane_web` | sim | `JobComponents`, `JobLive`, `TaskLive.Show`, testes |
| `claude_control_plane` (domínio) | não | — |
| `claude_control_plane_protocol` | não | — |
| `claude_control_plane_runner` | só o CLI falso dos testes | um marcador novo em `test/support/fake_claude` para o e2e ao vivo (ver abaixo); nenhum código de produção |

**Migrations:** nenhuma. **Protocolo runner ↔ control plane:** sem impacto. Só apresentação.

### Decisões (os dois pontos a conferir)

**D1. O painel abre por `Phoenix.LiveView.JS`, sem ida ao servidor.**

O clique no ícone `<id>` da linha do tempo `<tl>` executa:

```elixir
JS.hide(to: "##{tl} [data-event-panel]:not(##{panel_id})")
|> JS.remove_class("ring-2 …", to: "##{tl} [data-event-icon]:not(##{icon_id})")
|> JS.set_attribute({"aria-expanded", "false"}, to: "##{tl} [data-event-icon]:not(##{icon_id})")
|> JS.toggle(to: "##{panel_id}")
|> JS.toggle_class("ring-2 …", to: "##{icon_id}")
|> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{icon_id}")
```

Os painéis de todos os ícones da faixa são renderizados (escondidos, `class="hidden"`)
logo abaixo dos ícones, dentro do segmento da faixa. É o mesmo HTML que a página já manda
hoje (hoje todo o conteúdo vai visível), então o peso não cresce.

Por que não estado na LiveView:

- **A página do job e a etapa ao vivo usam stream.** O servidor não guarda os eventos já
  enviados; abrir um painel de uma faixa antiga exigiria re-renderizar essa faixa, ou
  seja, reler eventos do banco ou guardar todos na memória do processo, só para um clique.
- Um clique é instantâneo, sem latência de ida e volta.
- As operações de `JS` são "sticky": sobrevivem aos patches do servidor no mesmo
  elemento, o que resolve D2 sem código extra.
- O custo: o ExUnit não executa `JS`. O ExUnit prova que o ícone e o painel existem, que
  o painel começa escondido e que o `phx-click` aponta para o painel certo; abrir, fechar
  e trocar são provados no e2e (o pedido já os põe lá).

**D2. Com um painel aberto, um evento novo atualiza a faixa sem fechá-lo.**

- O stream passa a ser de **segmentos**, não de eventos: `stream(:timeline, segmentos)`,
  com cada segmento um mapa `%{id: dom_id, kind: :strip | :text, events: [Event.t()]}`.
- O id da faixa vem do seu primeiro evento (`"strip-all-<event.id>"`), estável enquanto
  ela cresce. O id do bloco de texto é `"text-<event.id>"`.
- A LiveView guarda só a **cauda**: a faixa aberta no fim (seus eventos) e os `seq` já
  mostrados (um `MapSet` de inteiros, para descartar a duplicata da janela do mount).
- Evento novo de ícone com faixa aberta → `stream_insert(:timeline, faixa_com_o_novo)`
  com o mesmo id: o LiveView aplica um patch **no lugar**, o elemento do painel aberto é o
  mesmo (mesmo `id`), e o `display` posto pelo `JS.toggle` fica (sticky). O ícone novo
  entra fechado.
- Evento novo de texto → `stream_insert` de um bloco novo no fim; a cauda vira `nil`. A
  faixa anterior não é tocada, e o painel dela continua aberto.
- A decisão de onde o evento vai é uma função pura em `JobComponents` (abaixo); a
  LiveView só chama e faz o `stream_insert`.

Isso deixa o servidor com memória proporcional à faixa aberta, não à execução inteira. O
risco de a faixa aberta ser enorme é tratado em Riscos.

**D3. O agrupamento de leituras (`{:group, …}`) sai**, como explicado na especificação.

**D4. Tooltip:** `<.icon_button tooltip={…}>` do Petal; se o `tooltip` desse componente
não aceitar `aria-describedby`/posição de que precisamos, usar `<.tooltip label=…
placement="top">` envolvendo o `<.icon_button>`. Conferir os attrs reais no código do
pacote (`mix hex.package fetch petal_components 4.17.1 --unpack`) antes de escrever o
HEEx.

### Funções puras em `JobComponents` (todas com `@spec` e `@doc`)

```elixir
@type segment :: %{id: String.t(), kind: :strip | :text, events: [Event.t()]}
@type tail :: %{strip: segment() | nil, seen: MapSet.t(integer())}

# Qual evento vira ícone (a decisão do pedido, item 4).
@spec icon?(Event.t()) :: boolean()            # false só para assistant_text e result

# normal | error | denied
@spec event_state(Event.t()) :: :normal | :error | :denied

# O texto do tooltip (e, com o rótulo, do aria-label).
@spec event_summary(Event.t()) :: String.t()

# Lista inteira → segmentos, depois do filtro (substitui o `{:event | :group}` de hoje).
# O filtro entra no id das faixas ("strip-<filtro>-<event.id>"), para que trocar o
# filtro troque os ids e feche o painel aberto; ao vivo o filtro é sempre "all".
@spec timeline_items([Event.t()], String.t()) :: [segment()]

# Estado de cauda a partir dos segmentos lidos no mount.
@spec timeline_tail([segment()]) :: tail()

# Um evento ao vivo: o segmento a inserir no stream (ou :seen) e a cauda nova.
@spec timeline_push(tail(), Event.t()) :: {segment() | :seen, tail()}
```

`timeline_items/2` passa a ser implementada com `timeline_push/2` (um `reduce`), para que
a lista inteira e o ao vivo usem a mesma regra.

### Componentes

- `job_event/1` deixa de ser a linha inteira de todo evento. Fica:
  - `timeline/1` (novo, público): recebe `id` (o da linha do tempo, usado nos seletores
    do `JS`) e os segmentos, ou é usado por item do stream (`timeline_segment/1`);
  - `timeline_segment/1` (público, usado no `:for` do stream): faixa ou bloco;
  - `event_icon/1` (privado): o `<.icon_button>` com tooltip, `aria-label`,
    `aria-expanded`, `data-state`, `data-type`, `data-event-icon`, `phx-click` do D1;
  - `event_panel/1` (privado): cabeçalho + `event_body/1`, `hidden`, `data-event-panel`;
  - o bloco de texto reaproveita o cabeçalho e o corpo de hoje (recuo `ml-8` de
    subagente mantido).
- `event_look/1` ganha o campo do estado (cor do `icon_button`: `gray` | `danger`) e o
  ícone de tipo desconhecido deixa de se chamar "Fim da execução" (o `result` ganha
  cláusula própria).
- `event_body/1`: `thinking` e `tool_result` sem o `<details>` (o painel já é a
  abertura); `tool_result` vazio diz "Sem saída.".
- `steps/1`: passa a desenhar segmentos; sai o `job-event-group`.
- `@moduledoc` de `JobComponents` atualizado (faixas de ícones e painéis).

### LiveViews (finas: só chamam as funções puras)

- `JobLive`:
  - `mount`: `segments = timeline_items(events, "all")`,
    `assign(timeline_tail: timeline_tail(segments))`, `stream(:timeline, segments)`;
  - `handle_info({:job_event, e})`: `{seg, tail} = timeline_push(tail, e)`; se `:seen`,
    nada; senão `stream_insert(:timeline, seg)`; `event_count` e `typing` como hoje;
  - `#job-events` vira o contêiner do stream de segmentos (`phx-update="stream"`), com
    `data-testid="job-events"` mantido.
- `TaskLive.Show`:
  - `follow_running_job/1`: o mesmo, com `stream(:timeline, …, reset: true)` e a cauda
    zerada ao trocar de job;
  - `handle_info({:job_event, e})`: igual ao `JobLive`, só para `live_job_id`;
  - passo a passo terminado: `<.steps items={timeline_items(@steps, @steps_filter)} …>`
    sem mudança de fluxo; o filtro continua no servidor (`filter_steps`).
  - import de `JobComponents` atualizado (`job_event: 1` sai; entram os novos).

### CLI falso (só teste)

`apps/claude_control_plane_runner/test/support/fake_claude`: um marcador novo
`[gotejando]` que, depois do `tool_result`, espera ~3 s e emite mais um par
`tool_use` Bash + `tool_result`, e segue normalmente. Não mexe em `[lento]` (usado pelos
testes do runner). Serve para o e2e provar D2 de forma determinística: abrir um painel
durante a espera e ver o ícone novo chegar com o painel ainda aberto. Comentário de
cabeçalho do script atualizado.

### Ordem

1. Funções puras (`icon?`, `event_state`, `event_summary`, `timeline_items`,
   `timeline_tail`, `timeline_push`) + testes ExUnit delas.
2. Componentes (`timeline_segment`, ícone, painel, bloco) + testes de renderização.
3. `JobLive` e `TaskLive.Show` (stream de segmentos, cauda) + testes de LiveView.
4. `fake_claude` `[gotejando]`; e2e de job e de tarefa; Page Objects.
5. `make e2e.shots` (claro, escuro, ~800 px) e revisão das imagens.
6. Documentação (ADR, índice, roadmap) e `make ci`.

## 3. Testes por critério

### `data-testid` novos (convenção do `e2e/README.md`; a chave natural é o `seq`)

| Elemento | testid | Atributos para teste |
|---|---|---|
| faixa | `job-event-strip-<seq do 1º evento>` | — |
| ícone | `job-event-icon-<seq>` | `data-type`, `data-state`, `aria-expanded`, `aria-label` |
| painel | `job-event-panel-<seq>` | `data-type` |
| bloco de texto | `job-event-<seq>` | `data-type` |

Os testids se repetem entre linhas do tempo (o `seq` é por job); specs e testes sempre
escopam pelo contêiner: `job-events`, `task-events`, `stage-run-steps-<chave>-<tentativa>`.
Os ids de DOM usam o `event.id` (UUID) prefixado pelo id da linha do tempo, únicos na
página. O testid `job-event` (genérico) e `job-event-group` saem.

### ExUnit — `JobComponentsTest`

- `icon?/1`: verdadeiro para os oito tipos de ícone e um desconhecido; falso para
  `assistant_text` e `result` (crit. 1, 3).
- `event_state/1`: `tool_result` com erro → `:error`; `api_retry` → `:error`;
  `permission_denied` e decisão `reject` → `:denied`; o resto → `:normal` (crit. 2).
- `event_summary/1`: Bash com descrição; Bash sem descrição (primeira linha do comando,
  cortada); Read com o caminho; resultado com linhas; resultado negado; pensamento com a
  duração; limites com as janelas; subagente; tokens do turno (crit. 2).
- `timeline_items/2`: a lista do teste atual vira `[faixa(1..7), texto(8), faixa(9..10)]`;
  ícones seguidos numa faixa, texto interrompendo; cada filtro (`agent`, `tools`,
  `thinking` → uma faixa só de pensamento, `errors`) (crit. 1, 3, 6).
- `timeline_push/2`: ícone com faixa aberta → mesma faixa (mesmo id) com o evento no fim;
  ícone depois de texto → faixa nova; texto → bloco e cauda `nil`; `seq` já visto →
  `:seen`; `timeline_items` é o `reduce` de `timeline_push` (crit. 5).
- Renderização (`render_component`):
  - faixa: um `job-event-icon-<seq>` por evento, com `aria-label`, `data-state`,
    tooltip com o resumo, classe de cor `danger` nos de erro/negado;
  - painel: existe para cada ícone, começa `hidden`, traz o conteúdo de hoje (os testes
    de `$ mix test`, diff do Edit, Write recolhido, TodoWrite, argumentos, pensamento,
    "não mostra", limites, compactação, negação continuam, agora no painel);
  - o `phx-click` do ícone aponta para o painel dele (`JS` serializado contém o id);
  - bloco de texto: Markdown e tokens como hoje; subagente com `ml-8`; ícone de
    subagente com `data-subagent` (crit. 1–4).

### ExUnit — LiveViews

- `JobLiveTest`: os eventos do teste atual aparecem como ícones/blocos
  (`[data-testid=job-event-icon-2][data-type=tool_use]`, painel com "Write", bloco
  `job-event-5` com "feito"); um `{:job_event, …}` de ícone depois de outro ícone mantém
  a mesma faixa (`job-event-strip-<n>` com o ícone novo dentro); um de texto cria o bloco;
  um evento repetido não duplica o ícone (crit. 5).
- `TaskLiveTest`: a etapa ao vivo recebe ícones na faixa; o passo a passo terminado com
  os filtros (o teste atual de "trabalhando" adaptado), incluindo
  `stage-run-steps-filter-…-thinking` mostrando só ícones de pensamento (crit. 6).

### e2e (Playwright)

- `pages/JobsPage.ts`: `icon(seq)`, `panel(seq)`, `textEvent(seq)`, `icons()` (regex
  `/^job-event-icon-\d+$/` dentro de `job-events`), `openEvent(seq)`.
- `tests/job-execution.spec.ts`:
  - fluxo A: 4 ícones (sessão, pensamento, Write, resultado) e 2 blocos (resposta,
    resultado) no lugar de `toHaveCount(6)`; `data-state="normal"`; clicar no ícone do
    Write abre `job-event-panel-3` com o caminho; clicar no do pensamento troca; clicar de
    novo fecha (crit. 1, 3, 4);
  - fluxo novo `[gotejando]`: com os 4 primeiros ícones na tela, abrir o painel do
    pensamento; esperar `job-event-icon-5`; o painel do pensamento continua visível
    (crit. 5);
  - fluxo C (falha): o que houver de erro aparece como ícone `data-state="error"`;
  - `shot()` da faixa fechada, com painel aberto, e com painel aberto ao vivo.
- `tests/task-pipeline.spec.ts`: abrir o passo a passo de `triagem-1`, clicar num ícone
  (abre), em outro (troca), de novo (fecha); filtro "Raciocínio" mostra só o ícone de
  pensamento e abre o painel dele; `shot()` do passo a passo com painel aberto
  (crit. 4, 6).
- Largura estreita: as capturas da faixa e do painel também a ~800 px
  (`page.setViewportSize({ width: 800, height: … })` antes dos `shot()` dessas telas, ou
  um projeto do Playwright com essa largura, se `helpers/screenshots.ts` já tiver um
  mecanismo; conferir).
- `make e2e.shots`, claro e escuro, e leitura das imagens (crit. 8).

## 4. Documentação

- **ADR novo** `docs/adr/0016-linha-do-tempo-compacta.md`: faixas de ícones e blocos de
  texto; a regra de quem vira ícone; painel por `JS` (D1) e não por estado na LiveView;
  stream de segmentos com a cauda no servidor (D2); fim do agrupamento de leituras (D3).
  Consequências: o ExUnit não prova abrir/fechar (o e2e prova); a faixa aberta fica na
  memória do processo.
- `docs/README.md`: a linha do ADR 0016 no índice.
- `docs/plano/03-roadmap-orquestrador.md`, item 3 do Marco 2 ("Linha do tempo rica"):
  registrar a linha do tempo compacta (ADR 0016) e tirar "agrupamento" do que falta, já
  que filtros e agrupamento estão feitos.
- `e2e/README.md`: nada a mudar na convenção (a chave natural `seq` cabe na regra de
  registro); se o e2e passar a usar uma largura estreita nas capturas, uma linha sobre isso
  em "Evidência visual".
- Cabeçalho do `fake_claude`: o marcador `[gotejando]`.
- `@moduledoc` de `JobComponents`, `JobLive` e `TaskLive.Show` descrevendo faixas,
  painéis e o stream de segmentos.

## 5. Riscos

- **Sticky do `JS` no `stream_insert` da faixa.** Depende de o patch no lugar preservar o
  elemento do painel (mesmo `id`, mesmo pai). Se algum atributo que o servidor renderiza
  no painel (a classe `hidden`) for reaplicado e vencer o `display` do `JS`, o painel
  fecha. Mitigação: usar `JS.show/hide/toggle` (que o LiveView guarda como sticky) e não
  `add_class/remove_class` em `hidden`; o e2e `[gotejando]` prova. Plano B: um hook
  pequeno que guarda o id do painel aberto e o reabre em `updated()`.
- **Faixa aberta muito longa** (uma etapa com centenas de chamadas sem texto): cada
  evento novo reenvia a faixa inteira no `stream_insert` e a cauda cresce na memória.
  Mitigação, se aparecer: limitar a faixa a N ícones e abrir outra faixa depois (a regra
  fica em `timeline_push/2`, testável). Não está no pedido; fica anotado no ADR.
- **Painel longe do ícone** numa faixa de muitas linhas: o painel vem abaixo da faixa
  inteira. É o que o pedido descreve; o anel no ícone aberto ajuda a ligar os dois.
- **Tooltip cortado** pelo `overflow` do card ou pela borda a ~800 px. Conferir nas
  capturas; trocar `placement` ou tirar `overflow-hidden` do contêiner se preciso.
- **Contraste** dos ícones cinza no modo escuro e do vermelho de erro vs. negado:
  conferir nas capturas.
- **Testes que dependem do formato atual** (`job-event`, `job-event-group`,
  `{:event, _}`/`{:group, …}`, `toHaveCount(6)`, a saída de erro aberta por padrão):
  todos mudam junto, nesta tarefa.
- **Mudança de comportamento**: a saída de erro deixa de vir aberta, e o agrupamento
  "Leu N arquivos" some. Os dois seguem do pedido ("erros… só como ícone, abrem ao
  clicar"; ícones consecutivos se agrupam na faixa), e ficam registrados no ADR.
- **`icon_button` com `tooltip`**: se não aceitar o que precisamos (id para
  `aria-describedby`, `placement`), usar `<.tooltip>` envolvendo o botão (D4). Conferir os
  attrs reais no pacote antes.
