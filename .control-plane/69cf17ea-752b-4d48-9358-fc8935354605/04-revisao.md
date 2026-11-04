# 04 — Revisão de código: linha do tempo compacta com ícones dos eventos

Revisado: `git diff main...HEAD`, sem nada pendente de commit, contra a especificação e o
plano (`01-entendimento.md`) e as convenções do `AGENTS.md`.

**Veredito: aprovado, com ressalvas.** Não há problema grave. A mudança cumpre os critérios
1 a 7 e respeita as fronteiras: só o app web muda, mais o CLI falso de teste do runner.
Protocolo, domínio e banco ficaram intactos. As funções novas têm `@spec`/`@doc`, as
LiveViews só chamam as funções puras, o ícone usa `<.icon_button>` do Petal, os testids
seguem a convenção, e o ExUnit e o e2e cobrem o que cada um consegue provar. Os dois
primeiros itens abaixo devem ser tratados antes do merge.

## Média

### 1. A faixa ao vivo é reenviada inteira a cada evento, com todos os painéis

`job_components.ex:236-254` (`timeline_push/2`), `:293-314` (`timeline_segment/1`),
`job_live.ex:70-83`, `task_live/show.ex:63-73`.

Cada ícone novo faz `stream_insert` da faixa aberta inteira. O item de um stream não é
diffado: o HTML do `<li>` volta todo para o cliente, e isso inclui o painel completo de
cada evento da faixa (saídas de ferramenta, diffs do Edit, conteúdo do Write). A saída
das ferramentas não é truncada no runner (nada em `apps/claude_control_plane_runner/lib`
corta o `text` do evento). Uma etapa com dezenas de chamadas seguidas sem texto do agente
é comum: muitas leituras com o pensamento entre elas. Nesse caso o tráfego cresce de forma
quadrática. Com 50 `Read` de ~30 KB, cada evento novo manda ~1,5 MB. Antes desta mudança,
cada evento era enviado uma vez só. A cauda também guarda na memória do processo todos os
eventos da faixa aberta, com as saídas, e `strip.events ++ [event]` é O(n) a cada push.

O plano (§5, Riscos) aceitou esse risco "se aparecer", mas o caso típico de uma etapa
longa o faz aparecer. A correção é barata e cabe na regra pura que já existe: limitar a
faixa em `timeline_push/2` (por exemplo 20 ícones; depois disso, abrir uma faixa nova) e
cobrir com um teste em `JobComponentsTest`. O painel aberto numa faixa já fechada continua
aberto, porque essa faixa não recebe mais patches. Outra saída é registrar o limite e o
custo no ADR 0016, na etapa de documentação.

### 2. Mudança de infraestrutura fora do escopo, dentro do commit da implementação

`Makefile:12-16`, `config/test.exs:1-15`, `config/e2e.exs:11-21`, `config/worktree.exs`
(novo).

O commit `ae2212f` traz o banco e a porta de e2e por worktree. É útil e funciona, mas não
tem relação com a linha do tempo, e o `03-implementacao.md` não menciona a mudança.
Provavelmente ela veio do ambiente do worktree e entrou junto no commit. Se outras
branches trouxerem a mesma mudança, o merge vai dar conflito ou duplicar código. Ela
também tira o comentário padrão do Phoenix sobre `MIX_TEST_PARTITION` em
`config/test.exs`, mas o assunto continua coberto pelo comentário novo. A decisão é de
quem integra: separar isso num commit ou PR próprio, ou ao menos citar no PR desta tarefa.

## Baixa

### 3. Cards passam da janela a 800 px: confirmar se é regressão

O `03-implementacao.md` registra que, na captura `job-timeline-narrow`, os cards da página
do job vão até ~950 px numa janela de 800 px. A suspeita é a tabela da auditoria, que vem
de antes desta mudança. A causa não foi confirmada. O critério 8 pede capturas a ~800 px
sem corte. Vale gerar a mesma captura em `main` para descartar que o painel (por exemplo
um `<pre>` ou um diff sem quebra dentro de um `<li>` sem `min-w-0`) seja a causa. Se o
problema for anterior, fica fora desta tarefa, mas convém anotar no PR.

### 4. `@moduledoc` do `JobLive` com uma linha longa

`job_live.ex:3-8`: a linha "only the strip still open at its end is kept here, to grow it
in place. A queued or running job can" passa de 100 colunas. O formatter não mexe em
strings, então isso ficou de fora. Basta quebrar a linha como as vizinhas.

### 5. Dois comentários colados acima de `handle_info({:job_event, …})`

`job_live.ex:68-71`: o comentário de antes ("Events are numbered from 1, so the highest
seq counts them…") e o novo ("A new icon joins the open strip…") viraram um bloco só, sem
separação, e falam de coisas diferentes. O primeiro trata do `event_count`. Ficaria mais
claro com uma linha em branco entre os dois, ou num parágrafo único que fale das duas
coisas.

### 6. Atalho de import sem explicação suficiente

`job_components.ex:68-69`: `import PetalComponents.Timeline, only: []` desfaz o import
que o `use PetalComponents` faz, para liberar o nome `timeline/1`. O comentário só diz
"`timeline/1` here is the run's timeline, not Petal's", o que não deixa claro por que
existe um import vazio. Sugestão: "Drops Petal's `timeline/1`, imported by
`use ClaudeControlPlaneWeb, :html`, so this module's own can take the name." Outra opção é
evitar a colisão dando outro nome ao componente (`run_timeline/1`).

## Conferido e sem problema

- **Fronteiras:** só `claude_control_plane_web` muda, mais o `fake_claude` de teste do
  runner. Nada vai para o protocolo nem para o domínio.
- **Convenções:** os públicos novos têm `@spec` e `@doc` (`icon?/1`, `event_state/1`,
  `event_summary/1`, `timeline_items/2`, `timeline_tail/1`, `timeline_push/2`,
  `timeline/1`, `timeline_segment/1`). Os tipos `segment` e `tail` têm `@typedoc`. Os
  `@moduledoc` de `JobComponents`, `JobLive` e `TaskLive.Show` foram atualizados e os
  comentários descrevem o código.
- **LiveViews finas:** a regra de onde cada evento vai fica numa função pura
  (`timeline_push/2`), e `timeline_items/2` é o `reduce` dela, então a lista inteira e o ao
  vivo seguem a mesma regra.
- **D1/D2:** os ids de ícone e painel derivam do id do segmento, que contém o filtro ou o
  prefixo da linha do tempo. A tarefa pode ter duas linhas do tempo na mesma página, e elas
  não colidem. Os seletores do `JS` são escopados por `#timeline`. O `JS.toggle` e o
  `toggle_class`/`toggle_attribute` são sticky, e o fluxo D do e2e (`[gotejando]`) prova que
  o painel continua aberto quando a faixa cresce. Trocar o filtro troca os ids e fecha o
  painel, como a especificação pede.
- **Duplicata da janela entre subscribe e mount:** o `MapSet` de `seq` cuida dela, e há
  teste no `JobLiveTest`. No `TaskLive.Show`, o `with` também descarta os eventos de outro
  job.
- **Casos de borda:** `tool_result` vazio ("Sem saída."), `thinking` sem texto, tipo
  desconhecido (ícone genérico com o tipo como rótulo), subagente (`data-subagent` e
  contorno tracejado no ícone, `ml-8` no bloco), negação por `decision.reject` em
  `tool_use` e `tool_result`. Todos têm teste em `JobComponentsTest`.
- **Reaproveitamento:** `prompt_summary/2`, `tokens_label/1`, `auth_label/1`,
  `format_duration/1` e `lines_label/1` são reaproveitados. `utilization_labels/1` passou a
  ser compartilhada entre o tooltip e o corpo dos limites. `count_label/3` foi mantida
  porque `AuditComponents` a usa.
- **e2e:** os specs selecionam só por test id. A classe `Timeline` é escopada por
  contêiner, e o `TasksPage` ganhou `openSteps`/`filterSteps`. O cabeçalho `@flow` dos specs
  foi atualizado.
- **Documentação:** o ADR 0016, o índice e o roadmap ficaram para a etapa de documentação,
  como o plano previa (§4). Não é falha desta etapa, mas o ADR deve registrar o item 1, seja
  o limite da faixa, seja o custo aceito.
