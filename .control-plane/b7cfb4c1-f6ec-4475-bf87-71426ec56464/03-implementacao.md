# 03 — Implementação: atualizar runner automaticamente

Os testes da etapa 2 passam sem nenhuma alteração. Nenhum teste foi enfraquecido ou
corrigido.

## O que mudou, por app

### `apps/pipe_maestro_protocol`
- **Novo `PipeMaestroProtocol.Downloads`**: `targets/0`, `binary_name/1`,
  `checksums_name/0` e `parse_checksums/1`, que lê o formato do `sha256sum` nos modos
  texto e binário (`*`), ignora linhas fora do formato e põe o hash em minúsculas. É o
  contrato do `download_url`. Nenhuma mensagem do fio muda e `protocol_version` não sobe.

### `apps/pipe_maestro_web`
- `RunnerComponents`: os alvos vêm de `Downloads.targets/0` e os links de
  `Downloads.binary_name/1`. Os rótulos de tela continuam na web, e o HTML e os
  `data-testid` não mudam.
- `RunnerUpdate`: o `@moduledoc` descreve o conteúdo do `download_url`. O payload não muda.

### `apps/pipe_maestro_runner`
- **Novo `PipeMaestroRunner.SelfUpdate`**:
  - `target/0,2`: o alvo a partir do SO e da arquitetura.
  - `urls/3`: só aceita a mesma origem da plataforma (esquema, host e porta) e `https`;
    `http` só para loopback. Sem `download_url`, usa `<plataforma>/downloads/runner/`.
  - `install/2`:
    1. abre um temporário `.<nome>.update-<aleatório>` com `:exclusive` no diretório do
       binário. Se não puder escrever (`:eacces`, `:erofs`, `:eperm`), devolve
       `{:not_writable, dir}` antes de qualquer requisição;
    2. baixa o `SHA256SUMS`. As requisições usam Req com `retry: false`,
       `redirect: false` e `decode_body: false`;
    3. faz o streaming do binário (`into:` função), soma o SHA-256 incrementalmente e
       mostra o progresso quando há `content-length`;
    4. confere o hash, faz `:file.sync`, `chmod 0755` e `rename`;
    5. apaga o temporário em `after`.
  - `clean_stale/1`: apaga os temporários que sobraram.
  - `relaunch/3,4`: no modo interativo, roda o binário com `Port` e `:nouse_stdio`, que
    herda o terminal, e devolve o código de saída do filho. No modo serviço, chama
    `halt(0)`, que pode ser injetado.
  - `child_env/1`: tira do filho `__BURRITO*`, `RELEASE_*`, `ROOTDIR`, `BINDIR`, `EMU` e
    `PROGNAME`.
- **`PipeMaestroRunner.Update`**: ganha `prompt/1`, `manual/2` e `handle/2`. A decisão
  segue o plano:
  - sem `__BURRITO_BIN_PATH`, ou sem TTY e sem `--auto-update`: mensagem de hoje;
  - com TTY: pergunta. Enter, `s`, `sim`, `y` ou `yes` contam como sim; o resto e o
    `:eof` contam como não;
  - com `--auto-update`: modo `:interactive` com TTY e `:service` sem TTY.

  Erros:
  - sem escrita: o texto manual, com `curl`, `shasum -a 256 -c`, `chmod`, `mv` e sem
    `sudo`;
  - outros erros: o motivo seguido da mensagem de hoje.

  Os padrões de `handle/2` vêm do ambiente: `System.get_env/0`, `Output.tty?/0`,
  `Output.ask/1` e uma reexecução que termina com `System.halt/1` usando o código do
  filho (spec `no_return`). A chave `config :pipe_maestro_runner, :update_prompt,
  binary: <caminho>` força a pergunta sob Mix.
- **`Output`**: ganha `ask/1` (`IO.gets`, com `:eof` no fim da entrada), `tty?/0`
  (`false` sob Mix; fora dele, `:io.getopts(:standard_io)[:terminal]`) e `progress/1`
  (uma linha em stderr, nada sob Mix).
- **`Commands.Start`**:
  - `--auto-update` entra em `@switches`;
  - na partida, apaga os temporários antigos quando roda como binário único;
  - em `{:outdated, refusal}`, chama `Update.handle/2` com `argv: ["start" | args]` e
    `platform_url: config.url`. Isso vale para o join e para o rejoin.
- **`Commands.Login`**: `--auto-update` entra em `@switches`. Em `{:outdated, refusal}`,
  chama `Update.handle/2` com `argv: ["login" | args]` e a `--url`.
- **`Main`**: o uso lista `--auto-update` em `login` e `start`. O argv da reexecução é
  `[comando | args]`, montado pelo próprio comando, e por isso `Main.run/1` não mudou.
- **`Service.program/1`**: o binário Burrito roda `[bin, "start", "--auto-update"]`.
- **`mix.exs`**: `test_ignore_filters` para `test/support/`. Sem isso, o
  `download_server.exs` carregado pelo `test_helper.exs` gerava o aviso "do not match
  any of the configured test_load_filters", que quebraria `--warnings-as-errors`.

### Configuração e documentação
- `config/e2e.exs`: `config :pipe_maestro_runner, :update_prompt, binary: <tmp>`.
- **ADR nova**: `docs/adr/0025-atualizacao-automatica-do-runner.md`.
- `docs/guias/instalacao.md`: a pergunta, `--auto-update`, o serviço (reinstalar),
  o caso sem permissão, a primeira atualização no deploy seguinte e o dev.
- `docs/guias/deploy.md`: o `RUNNER_DOWNLOADS_URL` precisa estar na mesma origem.
- `docs/specs/protocolo-runner.md`: a convenção do `download_url` e as regras do runner
  no `409` do login e no join.

## Runner antigo (protocolo)
O payload da recusa é o mesmo. Um runner anterior a esta versão mostra a mensagem da ADR
0023 e sai, como antes. Isso fica coberto pelos testes de `outdated` que já existiam em
`connection_test.exs` e `device_login_test.exs`, que continuam passando sem mudança.

## Como verificar
- `cd apps/pipe_maestro_protocol && mix test`: 76 testes passam.
- `cd apps/pipe_maestro_runner && mix test --warnings-as-errors`: 155 testes passam,
  entre eles `self_update_test.exs` e `update_test.exs`, com o servidor Bandit local.
- `make ci`: código 0, com Dialyzer e 0 erros.
- `make ci.quick > /tmp/ciq.log 2>&1; echo $?`: código 0.
- `make e2e`: os 16 testes passam, incluindo o fluxo E de `runner-connection.spec.ts`, em
  que a pergunta aparece no `login` e no `start` e a resposta "n" mantém a mensagem de
  hoje.

## Pendente (validação manual para o PR, não automatizável no CI)
Gerar o binário real (`make runner.binary`) para o alvo local, servir o diretório e
conferir:
- a pergunta, o "sim", a troca e a reexecução no terminal (herança do TTY pelo
  `:nouse_stdio`);
- o Ctrl+C depois da reexecução.

Se a herança do terminal falhar em algum alvo, a alternativa descrita na ADR 0025 é
trocar o binário e pedir para rodar de novo. Ela não foi implementada: hoje só existe o
caminho de reexecução.
