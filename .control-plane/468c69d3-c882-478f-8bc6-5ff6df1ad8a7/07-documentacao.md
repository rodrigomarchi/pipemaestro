# 07 — Documentação e resumo para a revisão

## Resumo

A aba **Etapas** da tarefa (`/w/:slug/tasks/:id`) passou a funcionar em fases:

1. **Visão geral leve:** o pipeline na vertical, só com estado, tentativas, grupo, duração e custo de cada etapa. Ao lado, o que é da tarefa inteira (alertas de runner, mensagem, pausa, interrupção, correção). Um aviso de decisão fica acima do pipeline, com o botão **Decidir**.
2. **Painel da etapa**, de 90% da largura (100% no celular), aberto ao clicar num nó e mantido na URL (`?etapa=<key>`). Lê as tentativas da etapa só ao abrir. Com a etapa rodando, mostra o ao vivo daquele job (inclusive em paralelo); ao terminar, passa sozinho ao artefato.

### Por app

- **`pipe_maestro` (domínio), sem migração:** `Tasks.get_task_overview!/2` (tarefa sem o que cada etapa produziu), `Tasks.stage_attempts/2` (tentativas de uma etapa, com os jobs completos), `Tasks.changed_files/1` e `Jobs.unsubscribe/1`. O payload de `Tasks.notify/1` e os tópicos de PubSub não mudaram.
- **`pipe_maestro_web`:** `TaskLive.Show` ficou fino. Módulos novos em `live/task_live/`: `PipelineView`, `StagePanel` (LiveComponent), `AttemptComponents`, `DecisionPanel` e as abas `SummaryTab`, `RequestTab`, `FilesTab`, `AttachmentsTab`, `DecisionsTab`. `PipelineComponents.side_panel/1` ganhou `size: :wide` e `backdrop`, com o padrão antigo preservado.
- **`pipe_maestro_protocol` e `pipe_maestro_runner`:** não mudam, a não ser pela linha de `mix.exs` da cobertura, abaixo.
- **Umbrella (cobertura):** `test_coverage.exs` na raiz (`PipeMaestro.TestCoverage`) gera o mesmo relatório do Mix, mas grava o HTML 16 módulos por vez. O `mix test --cover` do Mix esgotava os 256 descritores de arquivo (padrão do macOS) e falhava com `emfile`, também na `origin/main`.
- **e2e:** `TasksPage.ts`, os specs da tarefa e `director/landing.spec.ts` abrem a etapa antes de ler o que ela produziu; spec novo `tests/task-stage-panel.spec.ts`.

### Protocolo

Não muda: nem `apps/pipe_maestro_protocol`, nem as mensagens dos Channels, nem a versão. Runners antigos não são afetados.

## Riscos e onde olhar

- **Ao vivo:** `TaskLive.Show` (`follow_job/1`, as cláusulas de `handle_info` por `job_id`) e `StagePanel.update/2`. Conferir que trocar de etapa ou fechar o painel solta a assinatura e que eventos de outro job são descartados.
- **Recarga do painel:** só quando a impressão das tentativas da etapa aberta muda (`fingerprint/2`). Se um campo que o painel mostra mudar sem mexer em `updated_at`, ele não recarrega.
- **Projeção leve:** quem lê `@task` na página não pode usar `artifact`, `result`, `prompt`, `stderr`, `structured_output` nem `insights` (vêm `nil`). Isso vale para código novo na página.
- **`test_coverage.exs`:** substitui a ferramenta de cobertura do Mix nos quatro apps; o `mix.exs` só o carrega se o arquivo existir (a imagem Docker copia só os `mix.exs`).
- **Merge com a `origin/main`:** integrei o PR #39 (barra superior em uma linha, ações no menu "Ações"). Houve um conflito em `e2e/pages/TasksPage.ts` (`removeWorktree`), resolvido mantendo o fechamento do painel e o `clickPageAction`.
- **Diretor da landing (`make landing.shots`):** estava fora do `make e2e` e usava ids que mudaram (`stage-<key>`, `stageRunStatus`, `decision-panel` na página). Adaptei, e achei de passagem que o `job-audit` já exigia abrir a aba "Auditoria" (quebra anterior a esta tarefa), corrigido. Rodei o diretor: passa. **Não** versionei as imagens da landing regeneradas: a imagem `task` agora mostraria o painel; vale decidir se atualiza.

## Como verificar

- `make ci > /tmp/ci.log 2>&1; echo $?` (e, no macOS, com `ulimit -n 256`).
- `make e2e FILE=tests/task-stage-panel.spec.ts`; `make e2e` (a suíte inteira, 37 specs, passou depois do merge).
- `make e2e.shots FILE=tests/task-stage-panel.spec.ts` e abrir `e2e/screenshots/task-stage-panel/`, claro e `-dark`.
- **Na tela:**
  1. Abrir uma tarefa com etapas concluídas: só o pipeline vertical, sem artefato no DOM.
  2. Clicar num nó: painel de 90%, artefato primeiro, `?etapa=<key>` na URL; X, Esc, fundo e voltar do navegador fecham.
  3. Com uma etapa rodando: abrir o painel mostra a timeline ao vivo e "até agora"; ao terminar vira artefato, sem recarregar.
  4. Num grupo em paralelo, abrir cada etapa em execução mostra o ao vivo dela.
  5. Tarefa aguardando decisão: aviso, **Decidir**, questionário e decisão manual no painel.
  6. Celular: uma coluna, painel em tela cheia.

## Documentos

- ADR nova: `docs/adr/0046-pagina-da-tarefa-em-fases.md`; a ADR 0040 §6 aponta para ela.
- `docs/README.md`: índice com as ADRs 0045 (que faltava) e 0046.
- `docs/guias/ui-petal.md`: seção "Painel lateral de detalhes".
- `e2e/README.md`: seção "Painéis de detalhe".
- `docs/specs/`: sem mudança (protocolo e máquina de estados não mudaram).
