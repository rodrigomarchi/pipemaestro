# 07 — Documentação e resumo para revisão

## O que mudou e por quê

Em **Tarefas → Escrever com IA**, a pessoa agora pode escolher o pipeline no pedido e, por padrão, a tarefa é criada e iniciada sozinha quando o agente termina. Antes, ela tinha que abrir a proposta, o formulário e criar a tarefa, esperando com a página aberta.

### `apps/pipe_maestro` (domínio)
- `Proposals.TaskKind`: campos `pipeline_id` (validado no workspace) e `auto_approve` (ausente = desligado, o que preserva a triagem por webhook e os pedidos antigos). Com pipeline escolhido, o prompt cita só ele e o resultado o usa.
- `Proposals.job_finished/1`, chamado por `Jobs.finished/1`: cria a tarefa em nome de quem pediu e registra `task.auto_created` no `Audit`. Quando não cria, guarda o motivo no contexto da proposta.
- `Proposals.create_task/4` é o único caminho de criação a partir de proposta.
- Idempotência: migração `tasks.proposal_job_id` com índice único parcial. Terminar duas vezes ou criar à mão depois não gera segunda tarefa.
- `Jobs.update_proposal/2` faz o merge no contexto sob lock e notifica a tela.

### `apps/pipe_maestro_web`
- `ProposalRequest`: select de pipeline e switch de auto-aprovação (ligado por padrão).
- `ProposalLive.Show`: link "Abrir a tarefa", aviso com o motivo quando não foi criada, e redirecionamento ao vivo.
- `TaskLive.Index`: `?proposta=` de proposta já convertida leva à tarefa.
- `AuditLive`: rótulo da nova ação.

### Protocolo e runner
**O protocolo não mudou** e o runner não foi tocado. Os dados novos ficam em `context["proposal"]`, que não chega ao runner. Não há versão nova nem tratamento de runner antigo: runners antigos seguem compatíveis.

## Riscos e o que olhar com mais atenção
- **Criação sem ninguém na tela:** `Proposals.job_finished/1` roda no fim do job. Confira o tratamento dos erros (runner offline, quem pediu fora do workspace) e que o motivo é gravado.
- **Idempotência:** o índice único parcial e a migração (`priv/repo/migrations/*_add_proposal_job_to_tasks.exs`, `on_delete: :nilify_all`).
- **Padrão ligado:** o padrão "ligado" vem só do formulário. Pedidos sem o campo continuam sem auto-aprovar.
- Teste e2e: o `setChecked` do page object usa `force: true` por causa do switch do Petal; ele continua conferindo o estado final.
- `make ci` completo rodou sem erros na etapa de CI (exit 0, ver `05-ci.md`); depois dele só mudaram documentação e o spec e2e, fora do `make ci`.

## Como verificar
```sh
make ci > /tmp/ci.log 2>&1; echo $?
make e2e FILE=tests/agent-proposals.spec.ts
make e2e.shots FILE=tests/agent-proposals.spec.ts
```
Passos manuais: em Tarefas → Escrever com IA, confira o select "Deixar o agente escolher" e o switch ligado. Peça uma tarefa e veja a tarefa nascer e iniciar, com o pipeline escolhido. Desligue o switch, ou deixe o agente fazer perguntas, e veja o aviso com o motivo e o botão "Revisar e criar a tarefa". Depois da criação, abra a proposta de novo e veja o link "Abrir a tarefa" no lugar do botão.

## Documentos
- ADR nova: `docs/adr/0031-auto-aprovacao-da-tarefa-escrita-com-ia.md`, agora no índice de `docs/README.md`.
- ADR 0022: a tabela de tipos aponta para a 0031.
- `docs/specs/maquina-de-estados-tarefa.md`: origem de uma tarefa numa proposta e `proposal_job_id`.
- `docs/specs/protocolo-runner.md`, `docs/guias/*` e `e2e/README.md`: sem mudança necessária.
