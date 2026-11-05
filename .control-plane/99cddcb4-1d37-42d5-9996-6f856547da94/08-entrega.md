# 08 — Entrega

## Status: pronta para revisão (sem push e sem PR)

Como pedido, esta etapa não fez push nem abriu PR. A plataforma faz o push e marca o PR como pronto.

## Branch
- `cp/escolher-o-pipeline-e-auto-aprovar-ligad-99cddcb4` (confirmada: não é `main`).

## Atualização com a `main`
- `git fetch origin` feito. O `origin/main` (`979176e`, PR #10) já é ancestral da branch, então `git merge origin/main` não trouxe nada e não foi preciso rodar o CI de novo por isso.
- Árvore de trabalho limpa antes da entrega; nenhum commit novo nesta etapa, além deste artefato.

## Commits da tarefa (sobre `origin/main`)
```
bb47fea Testes: pipeline escolhido e auto-aprovação da tarefa escrita com IA
2d847f5 Testes que falham: plano e registro da etapa 2
450c8e7 Domínio: pipeline escolhido e auto-aprovação da tarefa escrita com IA
a20c031 Web: pipeline e auto-aprovação no pedido de tarefa, link para a tarefa criada
18b6a9e Web: test id do pipeline na página da tarefa
9f5bc55 Documentação: ADR 0031 da auto-aprovação da tarefa escrita com IA
11cb0fa e2e: alternar o switch do Petal pelo label que o cobre
da80d0f Implementação: registro da etapa 3
4842f15 e2e: marca os fluxos D e E das propostas como feitos
289f04b Revisão de convenções: registro da etapa 4
5078adc Telas (e2e): registro da etapa 6
f490a36 Documentação: índice da ADR 0031 e resumo para revisão
```

As mensagens estão em português e descrevem o que cada commit faz. Não há commit de lixo (logs ou screenshots).

## Verificação
- `make ci` (etapa 5): exit 0, sem warnings, format, deps, credo, testes com cobertura (81,59%) e dialyzer sem erros. Depois dele só mudaram documentação, `docs/README.md` e `e2e/tests/agent-proposals.spec.ts`, que não fazem parte do `make ci`.
- `make e2e` (etapa 6): 22 de 22 passaram. Screenshots claras e escuras conferidas.

## Resumo para quem for revisar o PR

Em **Tarefas → Escrever com IA**, a pessoa escolhe o pipeline no pedido. Por padrão, a tarefa é criada e iniciada sozinha quando o agente termina. Antes, ela precisava abrir a proposta, o formulário e criar a tarefa à mão.

- **Domínio (`apps/pipe_maestro`):** `Proposals.TaskKind` ganhou `pipeline_id` (validado no workspace) e `auto_approve` (ausente = desligado, o que preserva a triagem por webhook e os pedidos antigos). `Proposals.job_finished/1` cria a tarefa em nome de quem pediu e registra `task.auto_created` no `Audit`. Se não criar, guarda o motivo no contexto da proposta. `Proposals.create_task/4` é o único caminho de criação a partir de proposta. A migração `tasks.proposal_job_id` tem índice único parcial, então terminar duas vezes não gera segunda tarefa.
- **Web (`apps/pipe_maestro_web`):** select de pipeline e switch de auto-aprovação (ligado por padrão) no pedido. Na proposta, o link "Abrir a tarefa" e o aviso com o motivo quando a tarefa não foi criada. `?proposta=` leva à tarefa já criada.
- **Protocolo e runner:** não mudaram. Os dados novos ficam em `context["proposal"]`, que não chega ao runner, então runners antigos seguem compatíveis.
- **Documentos:** ADR `docs/adr/0031-auto-aprovacao-da-tarefa-escrita-com-ia.md`, indexada em `docs/README.md`; a ADR 0022 aponta para ela; `docs/specs/maquina-de-estados-tarefa.md` ganhou a origem da tarefa numa proposta.

### Pontos de atenção na revisão
- **Criação sem ninguém na tela:** `Proposals.job_finished/1` roda no fim do job. Conferir o tratamento de erros (runner offline, quem pediu fora do workspace) e a gravação do motivo.
- **Idempotência:** índice único parcial e migração (`on_delete: :nilify_all`).
- **Padrão ligado:** vem só do formulário. Pedidos sem o campo continuam sem auto-aprovar.
- **E2E:** o `setChecked` do page object usa `force: true` por causa do switch do Petal; ele continua conferindo o estado final.

### Como verificar
```sh
make ci > /tmp/ci.log 2>&1; echo $?
make e2e FILE=tests/agent-proposals.spec.ts
make e2e.shots FILE=tests/agent-proposals.spec.ts
```

Passos manuais: em Tarefas → Escrever com IA, conferir o select "Deixar o agente escolher" e o switch ligado. Pedir uma tarefa e ver a tarefa nascer e iniciar, com o pipeline escolhido. Desligar o switch, ou deixar o agente fazer perguntas, e ver o aviso com o motivo e o botão "Revisar e criar a tarefa". Depois da criação, abrir a proposta de novo e ver o link "Abrir a tarefa" no lugar do botão.

## Correção feita nesta etapa
- `07-documentacao.md` dizia que o `make ci` completo não tinha rodado de uma vez. O registro da etapa 5 (`05-ci.md`) diz que rodou com exit 0. A frase foi corrigida para apontar para `05-ci.md`.
