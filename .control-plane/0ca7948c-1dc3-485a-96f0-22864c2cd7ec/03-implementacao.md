# Implementação: atualização automática como padrão do runner

Os testes da etapa 2 passam sem mudanças: nenhum foi enfraquecido nem corrigido.

## O que mudou, por app

### `apps/pipe_maestro_runner`
- `lib/pipe_maestro_runner/update.ex`: `consent/2` só pergunta (ou, sem terminal, recusa
  com a mensagem) quando `opts[:auto_update] == false` (`--no-auto-update`). Omitida ou
  `true`, a opção leva a atualizar sem perguntar: `:interactive` com terminal e `:service`
  sem ele. `@moduledoc` e `@doc` de `handle/2` descrevem o novo padrão.
- `lib/pipe_maestro_runner/service.ex`: o binário único grava `start`, sem `--auto-update`.
- `lib/pipe_maestro_runner/main.ex`, `commands/start.ex`, `commands/login.ex`: o uso e os
  `@moduledoc` mostram `[--no-auto-update]`. O switch `auto_update: :boolean` fica:
  `--auto-update` segue aceito e `--no-auto-update` vira `false`.
- `test/test_helper.exs`: a suíte apaga `GIT_CONFIG_PARAMETERS` e
  `PIPEMAESTRO_GIT_CREDENTIAL_FILE` do ambiente. Rodada por um agente de runner, ela herdava
  essas variáveis, e o `fake_claude` gravava `credencial-vista.txt` nos repositórios dos testes
  do `JobRunner`. Eram as 4 falhas sem relação com a tarefa apontadas na etapa 2.

### `apps/pipe_maestro`, `apps/pipe_maestro_web`, `apps/pipe_maestro_protocol`
Não mudam. O protocolo fica igual: mesmo payload `"outdated"`, `protocol_version` não sobe.

### E2E e config
- `config/e2e.exs`: o comentário de `:update_prompt` explica que, sem a opção, o runner
  atualizaria. Por isso as specs passam `--no-auto-update`, e o runner pergunta.
- `e2e/helpers/runnerProcess.ts`: o runner do e2e é iniciado sem as duas variáveis de
  credencial git do ambiente. Com elas, o `task-pipeline.spec.ts` falhava ("3 arquivos
  alterados", com `credencial-vista.txt`). A causa era a mesma das falhas do runner.
- `e2e/tests/runner-connection.spec.ts` (Flow E), alterado na etapa 2: passa sem mudança.

### Documentação
- Nova `docs/adr/0038-atualizacao-automatica-por-padrao.md`.
- `docs/adr/0025-…`: o status aponta a ADR 0038.
- `docs/guias/instalacao.md`, seção do runner desatualizado: atualizar é o padrão.
  `--no-auto-update` pergunta (com terminal) ou mostra a mensagem (sem terminal). O serviço
  grava `start`, e os serviços antigos com `--auto-update` seguem valendo.
- `docs/specs/protocolo-runner.md` e `docs/plano/03-roadmap-orquestrador.md`: o texto do
  comportamento mudou.

## Como verificar
- `cd apps/pipe_maestro_runner && mix test`: 202 testes, 0 falhas, inclusive com as
  variáveis de credencial no ambiente.
- `make ci.quick > /tmp/ciq.log 2>&1; echo $?`: `0`.
- `make e2e`: 27 passed (inclui o Flow E e o `task-pipeline`).
- `grep -rn "auto-update" docs apps/pipe_maestro_runner/lib`: `--auto-update` só aparece
  como opção aceita por compatibilidade.

Não rodado nesta etapa: `make ci` completo (com Dialyzer). `consent/2` mantém o tipo de
retorno.
