# Etapa 8 — Entrega: "Os alertas do Board"

## Branch

- **Branch:** `cp/os-alertas-do-board-e40fde38`
- **Base:** `main` (merge-base verificado com `git merge-base HEAD main`)
- **Árvore:** limpa antes da entrega (nenhuma mudança não commitada da tarefa).
- **Push e PR:** não feitos nesta etapa. A plataforma faz o push e marca o PR como pronto.

## Commits da branch

Intervalo `git log --oneline $(git merge-base HEAD main)..HEAD`, do mais recente ao mais antigo:

```
419bee6 Documentação e resumo: Os alertas do Board
e125781 Telas (e2e): Os alertas do Board
86c5426 CI verde: Os alertas do Board
f22186a Revisão de convenções: Os alertas do Board
e1079d2 Implementação: Os alertas do Board
9ceb322 style(web): ordem dos aliases em TaskLive.Show
d79eeba docs: alerta de limite some na renovação; RunnerStatus recarrega alertas
9acbcfa feat(web): alertas do Board e aviso da tarefa acompanham o runner ao vivo
0b575c2 feat(tasks): runner_offline?/2 e alerts_change_at/2
24b4eaa Testes que falham: Os alertas do Board
a2fc39f test: alertas do Board e da tarefa acompanham o runner ao vivo
d630073 Entendimento e plano: Os alertas do Board
9083e9a feat(runner): entrega em PR também no Forgejo
```

### Observações sobre os commits

- **`9083e9a` não é desta tarefa.** Ele está no intervalo porque ainda não está em `main`. Ele é de outra entrega (entrega em PR no Forgejo, ADR 0027, mudanças no runner). Quem revisar deve olhar só os 12 commits de cima, ou esperar que ele chegue a `main` antes.
- **Mensagens:** todas em português. Sete delas são só o nome da etapa do pipeline (`Entendimento e plano`, `Testes que falham`, `Implementação`, `Revisão de convenções`, `CI verde`, `Telas (e2e)`, `Documentação e resumo`), seguidas do nome da tarefa. Descrevem a etapa, não a mudança. Não reescrevi o histórico: rebase está fora das regras desta etapa. Quem revisar encontra o conteúdo real nos commits `feat`, `test` e `docs`.
- **Trailers:** alguns commits anteriores trazem `Co-Authored-By` de outros modelos (Opus 5.5, Sonnet 5.5). Esses trailers foram mantidos como estão.

## Resumo para quem vai revisar

Resumo da etapa de Documentação, transcrito de `07-documentacao.md`:

### Documentação

- **ADR nova: não.** A decisão já está nas ADRs 0012 e 0024. A tarefa cumpre o "atualiza ao vivo" que o Board já prometia.
- **ADR atualizada:** `docs/adr/0024-resumo-da-execucao-e-metricas-do-agente.md`. O item do limite da conta registra que o alerta some sozinho na renovação, com timer até o `resets_at` mais próximo e sem polling (commit `d79eeba`). O índice `docs/README.md` não muda.
- **Specs e guias:** nenhum muda. O protocolo, a máquina de estados e os guias de UI e Phoenix ficam como estão.
- `@moduledoc` de `BoardLive` e `RunnerStatus`, e `@doc` das funções novas de `Tasks`, foram atualizados junto com o código.

### O que mudou e por quê

O Board não reagia a tudo que muda o estado de um runner. O limite da conta só aparecia depois de recarregar a tela, e o alerta de limite nunca sumia sozinho. A tela da tarefa não dizia que o runner estava offline.

- **`apps/pipe_maestro` (domínio):** em `PipeMaestro.Tasks`, `runner_offline?/2` concentra a regra "tarefa `:running` num runner fora do conjunto de online", e `alerts/2` passa a usá-la. `alerts_change_at/2` devolve o próximo instante em que um alerta de limite vence por tempo. Sem schema e sem migração.
- **`apps/pipe_maestro_web`:**
  - `BoardLive`: `presence_diff` e `:runners_changed` recarregam só os alertas (`load_alerts/1`), não o `load_tasks/1` completo. Um timer `:alerts_expired` até o `resets_at` mais próximo, com teto de 24 h, faz o alerta de limite sumir na renovação.
  - `TaskLive.Show`: assina `RunnerStatus` e mostra o aviso `task-runner-offline` (`<.alert>` do Petal) enquanto a tarefa está `:running` com o runner offline.
  - `RunnerStatus`: só o `@moduledoc`.
- **e2e:** novo `e2e/tests/board-alerts.spec.ts`, com métodos novos em `AppPage` e `TasksPage`.
- **Protocolo e runner:** não mudam nesta tarefa. Os sinais usados (`presence_diff`, `:runners_changed`) são PubSub interno do control plane.

### Riscos e o que olhar com mais atenção

- **Timer do Board:** `load_alerts/1` cancela o timer anterior antes de agendar outro, e o timer só existe com o socket conectado. Confirmar que nenhum caminho acumula timers.
- **Custo:** `:runners_changed` também chega em `worktree:usage` e `runner:directories`, e cada um roda `alerts/2`. É uma consulta só, e o `presence_diff` ficou mais barato por não chamar mais `load_tasks/1`.
- **Fora do escopo:** o instante em que uma decisão passa a ficar atrasada não gera timer. Esse alerta continua dependendo de um evento ou de recarga.

## Validação registrada nas etapas anteriores

- **CI (etapa 5):** `make ci` com exit code 0 na primeira execução (compile sem warnings, format, deps.unlock, credo --strict, testes com cobertura, dialyzer). Nenhuma correção foi necessária.
- **Telas (etapa 6):** spec e2e `board-alerts` cobrindo o alerta de limite, o alerta de runner offline e o aviso da tarefa.
- **Documentação (etapa 7):** só documentação e `@doc`/`@moduledoc` mudaram; o código validado no CI não foi alterado depois.

Comandos para verificar:

```
make ci > /tmp/ci.log 2>&1; echo $?
make e2e FILE=tests/board-alerts.spec.ts
make e2e.shots FILE=tests/board-alerts.spec.ts   # claro e escuro
```

Testes focados:

- `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs`
- `apps/pipe_maestro_web/test/pipe_maestro_web/live/board_live_test.exs`
- `apps/pipe_maestro_web/test/pipe_maestro_web/live/task_live_test.exs`

Passos manuais:

1. Com um runner online, crie uma tarefa cujo prompt tenha `[lento] [limite]` e abra o Board. O card "Precisa de atenção" mostra o alerta de limite.
2. Pare o runner, sem recarregar. O alerta "runner offline" aparece.
3. Abra a tarefa. O aviso vermelho "A tarefa está parada: o runner … está offline." aparece.
4. Suba o runner de novo. Os dois avisos somem.

## Estado

- Branch pronta para revisão, sem push feito por esta etapa.
- Nada bloqueou a entrega.
