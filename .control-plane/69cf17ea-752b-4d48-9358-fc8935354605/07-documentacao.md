# 07 — Documentação e resumo: linha do tempo compacta com ícones dos eventos

## Documentação atualizada nesta etapa

- **ADR novo:** `docs/adr/0016-linha-do-tempo-compacta.md`. Registra as faixas de ícones
  e os blocos de texto, quem vira ícone, o painel aberto por `Phoenix.LiveView.JS` sem
  estado na LiveView, o stream de segmentos com a cauda no servidor (`timeline_push/2`),
  os filtros aplicados antes das faixas e o fim do agrupamento de leituras. Nas
  consequências está o custo aceito da faixa reenviada inteira a cada evento (item 1 da
  revisão), com a correção prevista caso ele apareça.
- **`docs/README.md`:** a linha do ADR 0016 entrou no índice.
- **`docs/adr/0014-pendencias-do-roadmap.md`:** o item do agrupamento de leituras agora
  aponta para o ADR 0016, que o substitui.
- **Roadmap** (`docs/plano/03-roadmap-orquestrador.md`, Marco 2, item 3): saiu o "faltam o
  agrupamento, os tokens por turno e os filtros", que já estava desatualizado (o ADR 0014
  resolveu isso). Entraram as referências aos ADRs 0014 e 0016 e a faixa de ícones.
- **`docs/guias/ui-petal.md`:** uma nota sobre a colisão de um componente local com um do
  Petal e o `import PetalComponents.<Módulo>, only: []` que a resolve. Isso explica o
  import vazio de `JobComponents` (item 6 da revisão).
- **`e2e/README.md`:** como uma spec captura uma tela em largura estreita
  (`page.setViewportSize` antes do `shot()`).
- Não mudaram: `AGENTS.md` (nenhum contexto ou app ganhou papel novo) e `docs/specs/`
  (protocolo e máquina de estados intactos).

## Resumo para revisão e merge

### O que mudou

Na página do job, na etapa rodando da tarefa e no passo a passo de uma tentativa
terminada, os eventos sem texto (sessão, pensamento, chamada e resultado de ferramenta,
limites, retry, compactação, negação e tipo desconhecido) viram ícones lado a lado numa
faixa que quebra de linha. Cada ícone tem tooltip com o resumo, `aria-label` e cor por
estado (cinza normal, vermelho para erro e negação). Clicar abre, abaixo da faixa, um
painel com o conteúdo completo; clicar de novo fecha e clicar em outro troca. Respostas
do agente e o resultado continuam em largura total e encerram a faixa. Ao vivo, os
ícones novos entram na faixa e o painel aberto continua aberto. O agrupamento "Leu N
arquivos" saiu.

Código: só `claude_control_plane_web` (`JobComponents`, `JobLive`, `TaskLive.Show` e os
testes), mais o marcador `[gotejando]` no `fake_claude` de teste do runner e os specs e
Page Objects do e2e. Protocolo, domínio e banco não mudaram.

### Por quê

Com a auditoria (ADR 0015), os eventos sem texto passaram a ocupar a maior parte da linha
do tempo e a esconder as respostas, que são o que a pessoa lê. O painel por `JS` evita
guardar no servidor os eventos já enviados por stream, e o clique responde na hora.

### Como verificar

- `make ci` passou (etapa 6): compile, format, credo, testes com cobertura e dialyzer.
- `make e2e` passou com a suíte completa. `job-execution.spec.ts` (fluxos A e D,
  `[gotejando]`) e `task-pipeline.spec.ts` (fluxo H) provam abrir, trocar e fechar,
  o painel aberto durante a chegada de eventos e o filtro "Raciocínio".
- Visual: `make e2e.shots FILE="tests/job-execution.spec.ts tests/task-pipeline.spec.ts"`.
  As capturas a conferir são `job-event-panel-open`, `job-timeline-narrow`,
  `job-event-panel-open-live`, `task-steps-panel-open` e `task-steps-thinking`, no claro e
  no escuro.
- À mão: abrir um job com várias ferramentas, passar o mouse e usar Tab nos ícones
  (tooltip) e clicar para abrir e fechar os painéis.

### Riscos e pendências para quem integra

1. **Tráfego da faixa ao vivo** (revisão, item 1): cada ícone novo reenvia a faixa
   inteira com todos os painéis. Numa etapa longa sem texto do agente, isso cresce com o
   quadrado da faixa. O custo foi aceito e registrado no ADR 0016. A correção, se
   aparecer, é limitar a faixa em `timeline_push/2`.
2. **Infraestrutura de worktree no mesmo branch** (revisão, item 2): `Makefile`,
   `config/test.exs`, `config/e2e.exs` e `config/worktree.exs` (banco e porta de e2e por
   worktree) não têm relação com a linha do tempo. Separe num commit ou PR próprio, ou
   cite no PR, para evitar conflito com outras branches que tragam a mesma mudança.
3. **Cards a 800 px** (revisão, item 3): na captura estreita, os cards da página do job
   passam da janela. A linha do tempo cabe, e a suspeita é a tabela da auditoria, que é
   anterior a esta mudança. Isso não foi confirmado contra `main`.
4. **Mudança de comportamento:** a saída de erro deixa de vir aberta (abre no clique) e
   o resumo "Leu N arquivos" some. As duas coisas seguem o pedido e estão no ADR.
5. **Robustez anterior** (segurança): `utilization_labels/1` e `short_number/1` quebram
   com valor não numérico vindo do runner. Isso já acontecia antes, mas agora a mesma
   conta também roda no tooltip.
