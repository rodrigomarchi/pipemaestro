# Documentação e resumo para a revisão

## O que mudou e por quê

Um runner recusado por versão se atualizava, mas podia não voltar (fora do serviço
launchd/systemd, ou sem TTY), e os jobs em execução eram cancelados. Agora o runner volta
sozinho em qualquer forma de execução e um job perdido num restart roda de novo sem gastar
tentativa. A causa e as decisões D1 a D5 estão no plano (`01-plano.md`) e na ADR 0041.

- **`apps/pipe_maestro_runner`:** `Session` supervisiona `Outbox.Server`, `JobRunner` e
  `Connection.Keeper` (reconexão com backoff, sem perder a outbox). A recusa por versão
  drena os jobs em curso antes de atualizar. `SelfUpdate.mode/2` escolhe o modo pelo
  ambiente (`:service`, `:handoff`, `:interactive` com pai fixo, `:detached`).
  `InstanceLock` impede dois runners ao mesmo tempo. `Service` marca `PIPEMAESTRO_SERVICE=1`.
- **`apps/pipe_maestro` (domínio):** `Tasks.job_lost/1` e o status `:lost` do `StageRun`,
  com o campo `requeue` (migração em `priv/repo/migrations`). A etapa roda de novo na mesma
  tentativa; depois do limite de perdas a tarefa vai para `awaiting_decision`.
  `Jobs.reconcile/2` e `finish_job/3` tratam perda. Eventos novos `job_lost` e `update_draining`.
- **`apps/pipe_maestro_web`:** o canal reenvia credencial e cancelamento pendente a cada
  join; a tela da tarefa mostra a tentativa perdida e "de novo (n)"; a aba de eventos
  do runner ganha os rótulos novos.
- **`apps/pipe_maestro_protocol`:** `update_draining` entra no `runner:log`.

## O protocolo mudou?

Só de forma aditiva (evento de log); `protocol_version` não sobe. **Runner antigo:**
continua compatível. Recusado, ele cancela os jobs e sai pelo caminho antigo; o
`job:finished` `canceled` sem pedido conta como perda e a etapa roda de novo sem gastar
tentativa. Os jobs que ele não reporta voltam pela reconciliação. Fora do serviço, um
runner antigo ainda precisa ser reiniciado à mão uma vez (nota em `docs/guias/deploy.md`).

## Riscos e onde olhar

- O modo `:detached` (`trap "" HUP`, sem `nohup`) e o pai fixo do modo interativo foram
  verificados só com processos reais de teste. **Falta a reprodução ponta a ponta com o
  binário Burrito** (`service install` mexe no launchd da máquina), a fazer numa máquina
  que não seja a do runner do pipeline; passos em `03-implementacao.md`.
- Um `canceled` sem pedido agora vira perda: confira `Jobs.finish_job/3` e o limite
  `max_lost_requeues` (3).
- A drenagem espera até 30 min por padrão (`--drain-timeout`).
- Migração nova: `add_requeue_to_stage_runs` (padrão 0, aditiva).
- E2E: a rodada completa teve uma oscilação isolada em `integrations-issue-to-task`
  (passou sozinha); as portas fixas 4013/4014 colidem entre worktrees, tema à parte.

## Como verificar

```sh
make ci > /tmp/ci.log 2>&1; echo $?     # 0
make e2e FILE=tests/runner-restart.spec.ts
make e2e.shots FILE=tests/runner-restart.spec.ts   # claro e escuro
```

Passos manuais: com um servidor exigindo outra versão do runner, rodar o binário (a) no
terminal, (b) com `nohup ./pipemaestro start >log 2>&1 &`, (c) sob `pipemaestro service
install`. Em cada um ele deve baixar, trocar e voltar online sozinho; em (a), `ps` mostra
no máximo 2 BEAMs. Na tela da tarefa, matar o runner no meio de uma etapa deve mostrar
"Perdida (runner)" e "de novo (1)" sem gastar tentativa.

## ADRs e docs

- Nova: `docs/adr/0041-runner-resiliente-a-reinicios.md`, listada em `docs/README.md`
  (que também ganhou a 0040, que faltava no índice).
- Status atualizado nas ADRs 0023, 0025 e 0038.
- Specs: `docs/specs/protocolo-runner.md`, `docs/specs/maquina-de-estados-tarefa.md`.
- Guia: `docs/guias/deploy.md`. Roadmap: `docs/plano/03-roadmap-orquestrador.md` (Marco 1, item 4).
