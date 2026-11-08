# 0046 — A página da tarefa em fases

- **Status:** aceita
- **Data:** 08/11/2026
- **Relacionadas:** [ADR 0040](0040-diagrama-do-pipeline.md), [ADR 0039](0039-telemetria-do-runner.md), [ADR 0042](0042-arquivos-gerados-pela-etapa.md)

## Contexto

A aba "Etapas" da tarefa mostrava o pipeline inteiro de uma vez: o diagrama e, sob
ele, cada etapa com todas as tentativas, resumos, gates, arquivos e artefatos
renderizados. A tarefa ia inteira para o socket, com o `Job` completo de cada
tentativa, e cada `{:task_updated, task}` refazia o HTML de tudo. Só o primeiro job
em execução era seguido ao vivo, então as outras etapas de um grupo em paralelo não
apareciam. O `TaskLive.Show` juntava tudo isso num módulo só.

## Decisão

- **Duas fases na aba "Etapas".**
  1. **Visão geral:** o pipeline na vertical (entrada, cada passo, entrega em PR,
     fim), só com o que é leve: marcador, nome e badge de estado, tentativas, grupo
     e, com a etapa terminada, duração e custo da última tentativa. Ao lado, o que é
     da tarefa inteira: alertas de runner, mensagem, pausa, interrupção e correção.
  2. **Painel da etapa**, sob demanda: clicar num nó abre um painel de 90% da largura
     (todo o celular), com as tentativas da etapa, o artefato primeiro e o restante
     dobrado.
- **O desenho vertical é um componente próprio** (`TaskLive.PipelineView`), sobre o
  mesmo modelo (`PipelineDiagram.build/2` com `for_task/1` e `task_states/1`) e o
  mesmo vocabulário de estado. `pipeline_diagram/1` não ganhou orientação: as colunas,
  as bifurcações e o trilho "Pessoa decide" são horizontais, e os modos `:read`,
  `:edit`, `:compact` e `:micro` ficam como estão.
- **A etapa aberta está na URL**, `?etapa=<key>` junto de `?aba=`, por `push_patch`.
  O voltar do navegador fecha o painel, um link ou reload abre a mesma etapa, e uma
  `key` que não existe é ignorada.
- **A tarefa vai leve para o socket.** `Tasks.get_task_overview!/2` traz as tentativas
  e, de cada job, só status, custo e duração. As tentativas de uma etapa, com os jobs
  completos, vêm de `Tasks.stage_attempts/2` e só são lidas no painel; os arquivos
  alterados vêm de `Tasks.changed_files/1`. O payload de `Tasks.notify/1` e os tópicos
  do domínio não mudaram.
- **O painel é um LiveComponent** (`TaskLive.StagePanel`) com o próprio estado:
  tentativa escolhida, artefatos em texto, passo a passo aberto e seus filtros, a
  timeline ao vivo, o que o agente digita e o gasto até agora. Só relê do banco
  quando a etapa muda ou uma impressão das tentativas dela (id, status, `updated_at`
  e estado do job) muda.
- **O ao vivo é só do job da etapa aberta.** O LiveView assina `{:job, id}` do job
  em execução da etapa aberta e cancela a assinatura (`Jobs.unsubscribe/1`) ao fechar
  o painel ou trocar de etapa. Eventos, texto digitado e telemetria de outro job são
  descartados, e os da etapa seguida vão ao painel por `send_update/3`. Ao abrir, a
  timeline parte de `Jobs.list_events/1`. A telemetria mantém o intervalo de 2 s.
  Num grupo em paralelo, cada etapa mostra o ao vivo dela.
- **`side_panel/1` ganhou `size: :wide` e `backdrop`.** O padrão `:lg` mantém o
  painel das páginas de pipeline.
- **A decisão pendente** vira um aviso sobre o pipeline, com a razão e o botão
  "Decidir", que abre o painel da etapa que espera. O painel leva o questionário e a
  decisão manual (`TaskLive.DecisionPanel`).
- **O `Show` fica fino.** Cuida de `mount`, `handle_params`, das inscrições, do
  repasse ao painel e das ações da tarefa. As abas Resumo, Pedido, Arquivos, Anexos e
  Decisões e os componentes da tentativa moram em módulos próprios sob
  `live/task_live/`.

## Consequências

- A visão geral tem pouco DOM e não lê artefato, resultado nem eventos; abrir a página
  custa a mesma coisa com uma etapa ou com cem tentativas.
- Cada atualização da tarefa re-renderiza só o diagrama, e o painel só refaz a consulta
  da etapa aberta quando ela mudou.
- Todo elemento de uma tentativa passou a existir só com o painel aberto: specs e
  testes abrem a etapa antes de lê-lo.
- O painel guarda estado no servidor (um LiveComponent) enquanto está aberto; fechar o
  descarta.
