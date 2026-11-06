# Testes que falham: atualização automática como padrão do runner

Todos os testes ficam em `apps/pipe_maestro_runner` e no spec e2e do Flow E. Nenhum código de
produção mudou nesta etapa.

## Testes escritos ou ajustados

### `test/pipe_maestro_runner/update_test.exs`
- **Novos:**
  - `by default, without a terminal, it updates without asking, for the service manager`:
    `:auto_update` omitido e `tty?: false` → `:relaunched`, binário novo, `{:relaunch, bin, argv, :service}`, sem pergunta.
  - `by default, in a terminal, it updates without asking and runs again there`:
    `:auto_update` omitido e `tty?: true` → `:relaunched`, `:interactive`, sem pergunta.
- **Renomeados para o cenário `--no-auto-update`** (o setup já passa `auto_update: false`):
  as respostas "sim" e "não" à pergunta, o Ctrl+D e o caso sem terminal (a mensagem).
- **Ampliado:** `under Mix or a release (no single binary) it is the message, whatever the option`
  cobre `:auto_update` omitido, `true` e `false`.
- Mantidos: os casos `--auto-update` (compatibilidade com serviços já instalados).

### `test/pipe_maestro_runner/service_test.exs`
- `Service.program/1` do binário único → `{["/opt/cp/pipemaestro", "start"], "/opt/cp"}`.
- O plist e a unit do binário único rodam só `start` (`ExecStart=/opt/cp/pipemaestro start\n`),
  sem `auto-update`.

### `test/pipe_maestro_runner/main_test.exs`
- O uso lista `--no-auto-update` e não mostra mais `[--auto-update]`.

### `test/mix/tasks/runner_tasks_test.exs`
- `start` e `login` aceitam `--no-auto-update` e `--auto-update` (falham por falta de login e
  por não alcançar a URL, não por "Opção inválida"). Os dois já passam: o `OptionParser` com
  `auto_update: :boolean` já aceita a forma negada. Ficam como garantia de regressão.

### `e2e/tests/runner-connection.spec.ts` (Flow E)
- `runner.login` e `runner.start` desatualizados passam `--no-auto-update`. Com o novo padrão,
  sem a opção, o runner tentaria baixar em vez de perguntar. O `@flow E` diz que atualizar é
  o padrão. Com o código atual o spec continua válido, porque `--no-auto-update` (`false`) já leva à
  pergunta; o ajuste existe para o spec continuar verde depois da implementação.
- `make e2e.typecheck`: **passa** (saída 0).

## Execução

`mix format` sem erros. Rodando os quatro arquivos (`mix test` em `apps/pipe_maestro_runner`):
**35/40 passam, 5 falham**, todas pelo motivo esperado:

1. `service_test.exs:45`, "what the service runs":
   ```
   left:  {["/opt/cp/pipemaestro", "start", "--auto-update"], "/opt/cp"}
   right: {["/opt/cp/pipemaestro", "start"], "/opt/cp"}
   ```
   `Service.program/1` ainda grava `--auto-update`.
2. `service_test.exs:58`, "the single binary's service runs just start": o plist gerado ainda
   tem `<string>--auto-update</string>` antes de `</array>`. Mesmo motivo.
3. `update_test.exs:137`, "by default, without a terminal":
   ```
   left:  {:fail, "Este runner está na versão dev+abc1234, e a plataforma pede a versão dev+def5678 ..."}
   right: :relaunched
   ```
   Hoje, sem `auto_update: true` e sem terminal, `consent/2` recusa e devolve a mensagem.
4. `update_test.exs:149`, "by default, in a terminal":
   ```
   ** (RuntimeError) the test did not expect a question
     lib/pipe_maestro_runner/update.ex:106: PipeMaestroRunner.Update.consent/2
   ```
   Hoje, com terminal e sem a opção, `consent/2` pergunta. O `gets` do setup estoura justamente
   por isso.
5. `main_test.exs:26`, "the usage lists --version and --no-auto-update":
   ```
   assert usage =~ "--no-auto-update"
   left: "pipemaestro login [--url ...] [--auto-update] ...\n    pipemaestro start [--root ~/src] [--auto-update] ..."
   ```
   O texto de uso ainda mostra `[--auto-update]`.

## Testes que já existiam

Suíte inteira do runner: 202 testes. Falham os 5 acima e mais 4 de `job_runner_test.exs`
(`worktree setup ...`, `a stage in a directory without git ...`). Essas 4 falhas **não têm
relação com a tarefa**. Elas vêm do ambiente desta execução: o runner que roda o pipeline
exporta `GIT_CONFIG_PARAMETERS` (credential helper) e `PIPEMAESTRO_GIT_CREDENTIAL_FILE`, e
essas variáveis vazam para os repositórios git dos testes (aparece `credencial-vista.txt`
como mudança sem commit). Com
`env -u GIT_CONFIG_PARAMETERS -u PIPEMAESTRO_GIT_CREDENTIAL_FILE mix test test/pipe_maestro_runner/job_runner_test.exs`
os 42 passam. Para a implementação: rodar `make ci` sem essas variáveis, ou isolar o
ambiente git nesses testes, se o gate da plataforma rodar com elas.

Os demais testes do runner continuam passando.
