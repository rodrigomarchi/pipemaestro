# 0022 — Propostas do agente como mecanismo geral

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

A proposta de pipeline (ADR 0021) estabeleceu um padrão: a pessoa pede em linguagem
natural, o agente estuda o contexto pelo runner e responde num JSON Schema, e a pessoa
revisa antes de qualquer coisa ser salva. O mesmo padrão serve em outros pontos do
produto: escrever uma tarefa a partir de uma ideia (um meta prompt que gera o prompt da
tarefa), sugerir a decisão de uma tarefa parada, triar uma issue antes de ela virar
tarefa e melhorar um pipeline a partir de como as suas tarefas correram.

## Decisão

- **Tipos de proposta.** `PipeMaestro.Proposals` passa a ser o mecanismo comum, e cada
  tipo implementa `PipeMaestro.Proposals.Kind`: valida o pedido, monta o job (prompt,
  prompt de sistema, schema, orçamento) e lê a resposta. O contexto do job guarda
  `"proposal" => %{"kind", "input", "title"}`. A tela de revisão é uma só
  (`/w/:slug/proposals/:id`), com a timeline ao vivo e uma revisão por tipo, e
  `/w/:slug/proposals` lista as propostas.

  | Tipo | Onde se pede | O que a revisão permite |
  |---|---|---|
  | `pipeline` | Pipelines → Gerar com IA | salvar o projeto e abrir o pipeline preenchido |
  | `task` | Tarefas → Escrever com IA; triagem de issue ([ADR 0036](0036-integracoes-com-hosts-git.md)) | abrir a nova tarefa preenchida (título, prompt, pipeline, runner, diretório, issue); pedida pelo formulário, a tarefa pode ser criada sem revisão ([ADR 0031](0031-auto-aprovacao-da-tarefa-escrita-com-ia.md)) |
  | `decision` | painel de decisão da tarefa e página Decisões → Sugerir com IA | aplicar a ação sugerida (tentar de novo, avançar, cancelar) com as instruções editáveis |
  | `improve` | card do pipeline → Melhorar com IA | salvar as notas do projeto e abrir o pipeline preenchido, que vira a versão seguinte |
  | `analysis` | pedida pela própria plataforma quando a tarefa pausa por falha ([ADR 0029](0029-questionario-de-decisao.md)) | só ler o diagnóstico e as perguntas; a resposta acontece na tarefa |

- **Cada schema declara o tipo** no `$comment` (`"pipemaestro-kind:<tipo>"`): o CLI valida
  o `--json-schema` em modo estrito e recusa palavras-chave fora do JSON Schema, como uma
  extensão `x-`. Isso documenta a resposta e permite que o CLI falso do e2e responda a
  cada tipo.
- **Os dados de uma tarefa vão no prompt, não no worktree dela.** Uma análise de tarefa
  em andamento (`decision`) não lê o worktree da tarefa, porque as mudanças das etapas
  costumam não estar commitadas. O control plane já guarda os dados de cada tentativa:
  resumo, erro, gates reprovados (`Engine.feedback/3`), artefato e o diff (`changes`).
  Eles vão cortados no prompt, que fica abaixo do limite do job. O worktree descartável
  (`scratch`) serve só para ler o código-base. O protocolo não muda.
- **Histórico para melhorar.** `Tasks.history/2` traz as últimas tarefas finalizadas de
  um pipeline, com tentativas, gates reprovados, bloqueios e decisões. `Usage.report/2`
  dá o custo e a duração por etapa. O tipo `improve` resume os dois num digest.
- **Triagem de issue.** O projeto ganha `trigger_mode`: com `"task"` (o padrão), a label
  começa a tarefa como antes; com `"triage"`, o webhook pede uma proposta `task` ao
  primeiro runner online capaz que ofereça o diretório, em nome de quem configurou o
  gatilho, sugerindo o pipeline do gatilho. O corpo da issue entra cortado. Uma triagem em
  andamento da mesma issue não se repete, nem com duas entregas do GitHub ao mesmo tempo
  (trava por issue).
- **Proposta não recebe segredos.** O control plane não manda os segredos do workspace
  (`env`) num job de proposta. Uma triagem lê o corpo de uma issue, texto de fora, com
  todas as permissões, e estudar um projeto não precisa de segredo.
- **Uma decisão sugerida vale para uma pausa só.** A proposta guarda a etapa e quantas
  decisões a tarefa já tinha. Aplicar a sugestão confere que a tarefa ainda espera
  aquela mesma decisão; se ela seguiu e parou de novo, a sugestão não decide a pausa
  nova. Cancelar pela sugestão segue a regra de cancelar uma tarefa (quem a criou ou um
  admin).
- **A revisão vem antes dos dados.** Num pedido de nova rodada, a proposta anterior e o
  comentário da pessoa vão logo depois do pedido. O prompt é cortado no fim, nos dados
  mais longos, e nunca no comentário.
- **Quem revisa.** Propostas de tarefa e de decisão são de quem roda tarefas; as de
  pipeline e de melhoria são de admins, como os pipelines.

## Consequências

- Um ponto novo do produto que queira "pedir ao agente" declara um tipo e uma revisão.
  Pedido, runner capaz, worktree descartável, timeline e nova rodada já existem.
- Cada proposta é uma execução do agente, com limite de tempo por tipo, sem teto de custo (ADR 0028), e
  aparece em Execuções e em Propostas.
- A triagem precisa de um runner atualizado. Sem um, o webhook responde 422, como já
  fazia quando nenhum runner servia.
