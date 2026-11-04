# 01 — Plano: atualizar runner automaticamente

## Entendimento

Hoje (ADR 0023) um runner fora da versão da plataforma é recusado no `login` (HTTP 409,
`PipeMaestroRunner.DeviceLogin.request_code/3` → `{:error, {:outdated, refusal}}`) e no
join/rejoin do canal (`PipeMaestroRunner.Connection.handle_topic_close/3`, que chama
`stop_jobs/1` e avisa `{:outdated, refusal}`). Os comandos `Commands.Start.loop/2` e
`Commands.Login.run/1` param com `Output.fail!(Update.message(refusal))`. A pessoa abre
Executores, baixa o binário, troca o antigo e roda de novo.

**Com a mudança**, ao ser recusado por versão, o runner pergunta:

    Este runner está na versão dev+abc1234 e a plataforma está na dev+def5678.
    Baixar e instalar a versão dev+def5678 agora? [S/n]

- **"sim" ou Enter:** baixa `pipemaestro_<alvo>` da mesma origem da plataforma, confere
  o SHA-256 contra o `SHA256SUMS`, troca o executável de forma atômica (arquivo
  temporário no mesmo diretório, `chmod 0755`, `rename`) mostrando o progresso, e volta a
  rodar o mesmo comando com os mesmos argumentos, já na versão nova.
- **"não":** sai como hoje (mensagem de `Update.message/1`, código ≠ 0).
- **Sem TTY** (serviço, pipe): não pergunta. Sai como hoje, a menos que tenha sido
  iniciado com `--auto-update`, que atualiza sem perguntar. `pipemaestro service install`
  passa a gravar `start --auto-update` no launchd/systemd.
- **Pelo `mix`** (`make runner.*`): não pergunta, mostra a mensagem de hoje (o código é
  atualizado com `git`, não com binário).
- **Release Mix sem Burrito** (`bin/pipemaestro`, `RELEASE_ROOT`): não é um binário
  único; também mostra a mensagem de hoje.

### Critérios de aceite verificáveis

1. Aceitar → baixa, confere, troca e reexecuta (teste do runner com Bandit local e um
   "binário" que é um script de shell).
2. Recusar → mensagem de hoje, código ≠ 0, binário intacto.
3. Checksum errado (ou alvo ausente do `SHA256SUMS`) → aborta; binário atual idêntico
   (mesmo conteúdo, mesmo inode) e nenhum arquivo temporário sobrando.
4. Download interrompido (conexão fechada no meio, status ≠ 200) → mesmo que 3.
5. Sem TTY → não pergunta (nada lido da entrada), mensagem de hoje.
6. `--auto-update` → atualiza sem perguntar, com ou sem TTY.
7. Sem permissão de escrita no diretório do binário → mensagem com o caminho e o comando
   manual (curl + `shasum -a 256 -c` + `chmod` + `mv`), sem `sudo`, nada alterado.
8. Pelo `mix` → mensagem de hoje.
9. URL de download de outra origem, ou `http` para host que não é loopback → recusa
   baixar e mostra a mensagem de hoje.
10. Vale para `start` (join e rejoin) e `login`.
11. e2e: a pergunta aparece na recusa e "não" mantém o comportamento atual.
12. `make ci` e `make e2e` verdes.

## Como um binário Burrito sabe o próprio caminho e se reexecuta

- **Caminho:** o wrapper Zig do Burrito exporta `__BURRITO_BIN_PATH` para a VM que ele
  lança. O runner já usa isso em `PipeMaestroRunner.Service.program/1`. Essa variável
  também marca que o runner está num binário único. Sem ela, é Mix ou release, e não há
  atualização.
- **Reexecução:** o wrapper roda o `erlexec` como **processo filho** e sai com o código
  dele. A BEAM não tem `execve`, então não dá para substituir o próprio processo.
  Abordagem escolhida:
  - **Interativo (`start` ou `login` no terminal):** depois da troca, o runner abre o novo
    binário com `Port.open({:spawn_executable, bin}, [:nouse_stdio, :exit_status,
    args: argv, env: env_limpo])`. Com `:nouse_stdio`, o filho herda os fds 0, 1 e 2 da
    VM, ou seja, o terminal: a pessoa vê o novo runner como se fosse o mesmo. O processo
    antigo só espera o `exit_status` e sai com ele (`System.halt/1`). Do ambiente do
    filho saem as variáveis do Burrito e da release (`__BURRITO*`, `RELEASE_*`,
    `ROOTDIR`, `BINDIR`, `EMU`, `PROGNAME`) com `{name, false}`, para o novo wrapper não
    herdar o payload descompactado do antigo. Isso funciona porque cada build
    descompacta numa pasta própria: `binary_version/0` no `mix.exs` leva o momento do
    build.
  - **Serviço (`--auto-update` sem TTY):** depois da troca, o runner sai com código 0 e
    o gerenciador o reinicia no mesmo caminho, já com o binário novo (launchd com
    `KeepAlive`, systemd com `Restart=always`, conforme `Service.definition/2`). Assim
    não fica uma VM antiga pendurada como pai do processo.
  - **A validar na implementação** (com o binário real, `make runner.binary`): Ctrl+C
    durante o filho. O SIGINT vai ao grupo inteiro e a VM antiga não pode reagir antes do
    filho. Se o `:nouse_stdio` não herdar o TTY em algum alvo, a alternativa de menor
    fricção é trocar o binário e terminar com "Atualizado para X. Rode de novo:
    `<comando exato>`", com código 0. A troca automática continua, e só a reexecução vira
    um comando para copiar. O plano segue com a reexecução, e o fallback fica pronto no
    mesmo módulo.
- **`argv`:** `Main.run/1` recebe `[comando | args]` (`System.argv()`). Ele passa o
  argv original aos comandos (opção `:argv` ou `Application` env), e a reexecução usa
  exatamente esse argv.

## Mudanças por app

### `apps/pipe_maestro` (domínio)
**Não muda.** `PipeMaestro.Runners.version_check/1` continua igual. Não há schema nem
migração.

### `apps/pipe_maestro_web`
- `PipeMaestroWeb.RunnerUpdate`: **o payload não muda.** Só o `@moduledoc` passa a dizer
  que `download_url` é um diretório com `pipemaestro_<alvo>` e `SHA256SUMS`.
- `PipeMaestroWeb.RunnerComponents`: a lista `@downloads` deixa de repetir os alvos e
  passa a usar os de `PipeMaestroProtocol.Downloads` (abaixo). Os rótulos de tela ("macOS",
  "Apple Silicon") ficam na web. Os links e o HTML não mudam.
- Sem LiveView, Channel ou tela nova. As instruções de conexão
  (`connect_instructions/1`) não mudam.

### `apps/pipe_maestro_protocol`
Um módulo novo, sem efeito no fio: **`PipeMaestroProtocol.Downloads`**, o contrato do
diretório de binários, que o runner e a web precisam combinar:
- `targets/0` → `["macos_arm64", "macos_x86_64", "linux_x86_64", "linux_arm64"]`;
- `binary_name/1` → `"pipemaestro_" <> alvo`;
- `checksums_name/0` → `"SHA256SUMS"`;
- `parse_checksums/1` → mapa nome → sha256 em hex (formato `sha256sum`).

`protocol_version` não sobe e nenhuma mensagem do Channel muda (detalhes em "Protocolo").

### `apps/pipe_maestro_runner`
- **`PipeMaestroRunner.Update`** (existe): mantém `message/1` e ganha:
  - `prompt/1`, o texto da pergunta acima;
  - `manual/2`, a mensagem sem permissão de escrita, com o caminho e os comandos;
  - `handle(refusal, opts)`, a decisão. `opts` traz `argv`, `auto_update`, `platform_url`
    e as injeções de teste: `env`, `tty?`, `gets`, `req_options`, `relaunch`.
    O fluxo:
    1. sem `__BURRITO_BIN_PATH` (Mix ou release) → `{:fail, message}`;
    2. sem TTY e sem `--auto-update` → `{:fail, message}`;
    3. com TTY e sem `--auto-update` → pergunta; "n" ou "não" → `{:fail, message}`;
    4. caso contrário → `SelfUpdate.install/2`.

    Com `:ok`, chama `relaunch`. Com `{:error, motivo}`, devolve `{:fail, texto}` com o
    motivo e a mensagem de hoje.
- **`PipeMaestroRunner.SelfUpdate`** (novo), puro onde possível:
  - `target/0`: o alvo a partir de `:os.type/0` e
    `:erlang.system_info(:system_architecture)` (`aarch64-apple-darwin…` →
    `macos_arm64`, …). Não depende do Burrito e funciona nos testes.
  - `urls(platform_url, download_url, target)`: valida a origem. O esquema, o host e a
    porta do `download_url` precisam ser os de `config.url` (a plataforma a que o runner
    está conectado; no `login`, a `--url`). O esquema precisa ser `https`; `http` só vale
    para host de loopback (`localhost`, `127.0.0.1`, `::1`), que é o caso de dev, e2e e
    testes com Bandit. Sem `download_url`, o runner usa
    `platform_url <> "/downloads/runner/"`. Uma origem diferente dá
    `{:error, :foreign_origin}`.
  - `install(bin_path, opts)`:
    1. confere a escrita no diretório. Cria o temporário
       `.<nome>.update-<aleatório>` com `File.open(..., [:write, :exclusive])`; com
       `:eacces` ou `:erofs`, devolve `{:error, {:not_writable, dir}}`;
    2. baixa o `SHA256SUMS` (Req, `retry: false`, `redirect: false`, porque um redirect
       poderia levar a outra origem) e acha o hash do alvo;
    3. faz o streaming do binário para o temporário (`Req` com `into:` função), soma o
       SHA-256 incrementalmente (`:crypto.hash_update`) e mostra o progresso em %
       quando há `content-length`;
    4. com o status ≠ 200, a conexão interrompida ou o hash divergente, apaga o
       temporário e devolve erro, sem tocar no binário atual;
    5. faz `:file.sync`, `File.chmod(tmp, 0o755)` e `File.rename(tmp, bin_path)`. O
       `rename` é atômico no mesmo sistema de arquivos e cria um inode novo, o que evita
       o SIGKILL do macOS quando se sobrescreve um executável assinado.

    Garantia: o temporário é apagado em qualquer saída (`try/after`), e na partida o
    runner remove `.<nome>.update-*` antigos do diretório. Um download interrompido
    nunca deixa o binário pela metade.
  - `relaunch(bin, argv, mode)`: o `Port` com `:nouse_stdio` (interativo) ou a saída 0
    (serviço), como acima.
- **`Commands.Start`**: aceita `--auto-update` (`@switches`) e, no
  `{:outdated, refusal}`, chama `Update.handle/2` com o `argv`, o `auto_update` e o
  `config.url`. A conexão já parou e cancelou os jobs (`stop_jobs/1`), então nenhum job
  roda durante a atualização. Isso vale para o join e para o rejoin, que já passam pelo
  mesmo `handle_topic_close/3`.
- **`Commands.Login`**: aceita `--auto-update` e, em `{:error, {:outdated, refusal}}`,
  chama `Update.handle/2` com a `url` do login.
- **`PipeMaestroRunner.Main`**: passa o argv completo ao comando (para a reexecução) e
  marca a saída como `:stdio`, como já faz.
- **`PipeMaestroRunner.Service`**: `program/1` passa a devolver
  `[bin, "start", "--auto-update"]` para o binário Burrito. Para `RELEASE_ROOT` e para o
  `:development` fica igual, porque lá não há atualização.
- **`PipeMaestroRunner.Output`**: ganha `ask/2` (lê uma linha com `IO.gets`) e `tty?/0`.
  Para `tty?/0`: `:io.getopts(:standard_io)[:terminal]`, que o OTP ≥ 26 expõe também em
  `-noshell`. Sob Mix, devolve `false`. Pode ser substituído pelo app env
  `:pipe_maestro_runner, :update_prompt` (ver e2e).
- **Help de `Main`/`Commands.Start`**: documentar `--auto-update`.

## Fronteiras

- O runner continua dependendo só de `pipe_maestro_protocol`. Usa `Req` (já é
  dependência), `:crypto` (do OTP; acrescentar a `extra_applications` se o Dialyzer ou o
  release pedirem) e `Port`. Nenhum Phoenix ou Ecto.
- O módulo novo do protocolo (`Downloads`) não depende de nada do umbrella.
- A web passa a ler os alvos do protocolo, o que já é uma dependência permitida. O domínio
  não muda e continua sem web.

## Protocolo

- **Formato das mensagens do Channel e do HTTP: não muda.** A recusa continua
  `{"reason"/"error": "outdated", "version", "runner_version", "download_url"}`. O que
  faltava (o arquivo de cada plataforma e o checksum) sai de uma **convenção do
  `download_url`, que fica documentada**: é um diretório que contém
  `pipemaestro_<alvo>` para cada alvo e um `SHA256SUMS` no formato do `sha256sum`. A
  convenção já é o que `scripts/build_runner_binaries.sh` e `scripts/deploy.sh` publicam
  (ADR 0020), e passa a ter um lugar no código (`PipeMaestroProtocol.Downloads`).
  - Por que não acrescentar campos (`binaries`, `checksums_url`) ao payload: o runner
    teria de validar a origem de cada URL do mesmo jeito, e o control plane não sabe
    mais do que a convenção. Um campo novo só duplicaria a regra. Se um dia os binários
    saírem de um CDN, o acréscimo será aditivo e terá outra ADR.
- **`docs/specs/protocolo-runner.md`:** nas seções do login (`409`) e do join, explicar
  o conteúdo do `download_url` e as regras do runner: mesma origem que a plataforma,
  `https` (loopback aceita `http`), conferência do SHA-256 e troca atômica.
- **`protocol_version` não sobe.**
- **Runner antigo:** compatível. Ele recebe o mesmo payload de hoje, mostra a mensagem e
  sai (comportamento da ADR 0023). Só os runners com esta feature sabem se atualizar.
  Por isso a primeira atualização automática só acontece no deploy seguinte ao que
  publicar esta versão (está na seção "para validar depois do merge" da tarefa e vai
  para o guia).
- **Control plane com `RUNNER_DOWNLOADS_URL` absoluto em outra origem:** o runner se
  recusa a baixar (é a regra de segurança) e mostra a mensagem de hoje com o link. Isso
  fica documentado no guia de deploy.

## Telas

**Nenhuma tela muda.** Os links de download em Executores já existem
(`RunnerComponents.runner_downloads/1`, `data-testid="runner-downloads"` e um por alvo).
Não entram componentes Petal nem `data-testid` novos.

O e2e muda só no lado do CLI. `e2e/tests/runner-connection.spec.ts` (fluxo E) e
`e2e/helpers/runnerProcess.ts`:
- `RunnerProcess` ganha `write(text)`, que escreve no stdin do processo;
- o e2e roda o runner pelo `mix`, sem TTY, e as duas coisas fazem o runner não perguntar.
  Para o e2e ver a pergunta, `config/e2e.exs` define
  `config :pipe_maestro_runner, :update_prompt, true`. Isso força o caminho interativo
  sob Mix e sem TTY, com o executável a atualizar vindo do mesmo app env (apontando para
  um caminho temporário). Nos testes, isso só é usado com a resposta "não". É uma chave
  de teste, explícita e restrita ao `MIX_ENV=e2e`; em produção o comportamento continua
  sendo decidido pelo binário e pelo TTY;
- o fluxo E, no `login` e no `start`: espera
  `Baixar e instalar a versão <controlPlane> agora? [S/n]`, responde `n`, confere o
  código ≠ 0 e o texto de hoje (`versão X, e a plataforma está na Y`, o link
  `/downloads/runner/`). Atualizar o `@flow E` no cabeçalho do spec.

## Testes

ExUnit no runner (`apps/pipe_maestro_runner/test/pipe_maestro_runner/`). O servidor HTTP
local é Bandit + Plug, no padrão de `test/pipe_maestro_runner/telemetry/`, e serve
`/downloads/runner/pipemaestro_<alvo>` e `SHA256SUMS` de um diretório temporário.

- `self_update_test.exs`:
  - `target/0`: a arquitetura → alvo;
  - `urls/3`: mesma origem aceita; outra origem, `http` para host não-loopback e
    porta diferente recusados; sem `download_url`, usa o padrão;
  - `install/2`: o "binário" é um script `#!/bin/sh echo vNOVO`. Caso feliz: o arquivo
    trocado, `0755`, com o conteúdo novo e sem temporário. Checksum errado, alvo fora do
    `SHA256SUMS`, 404 e conexão fechada no meio (um Plug que manda metade e mata a
    conexão): o arquivo original fica intacto (mesmo inode e mesmo conteúdo) e nenhum
    `.update-*` sobra. Diretório sem escrita (`chmod 0555` no tmp; pular se rodar como
    root): `{:error, {:not_writable, dir}}` e nada criado;
  - limpeza dos temporários antigos.
- `update_test.exs`: `handle/2` com as injeções:
  - aceitar ("" ou "s") → baixa, troca e chama `relaunch` com o argv exato
    (`["start", "--root", "/x"]`). Um teste usa o `relaunch` real no modo interativo
    com o script de shell, para provar que o filho roda e que o código de saída dele
    volta;
  - "n" → `{:fail, message}` igual a `message/1`, sem nenhuma requisição (o Plug conta
    as requisições);
  - sem TTY e sem `--auto-update` → sem `gets`, mensagem de hoje;
  - `--auto-update` sem TTY → atualiza sem perguntar e usa o modo serviço;
  - sem permissão → texto com o caminho e o comando manual;
  - sem `__BURRITO_BIN_PATH` (Mix) → mensagem de hoje.
- `connection_test.exs` e `device_login_test.exs`: os testes existentes de `outdated`
  continuam valendo.
- `service_test.exs`: `program/1` com Burrito inclui `--auto-update`, e a plist e a unit
  levam o argumento.
- `main_test.exs`: o argv chega ao comando; `--auto-update` é aceito por `start` e
  `login`.
- `test/mix/tasks`: `runner.start` e `runner.login` recusados sob Mix mostram a mensagem
  de hoje.
- Protocolo: `downloads_test.exs` com `binary_name/1` e `parse_checksums/1` (linhas com
  `*`, espaços duplos, linha inválida ignorada).
- Web: o teste de `RunnerComponents` continua listando os quatro alvos.
- Playwright: o fluxo E acima.
- Validação manual registrada no PR (não automatizável no CI): `make runner.binary`
  com o alvo local, servir o diretório e conferir a pergunta, o "sim", a troca e a
  reexecução no terminal, e o Ctrl+C depois da reexecução.

## Documentação

- **ADR nova: `docs/adr/0025-atualizacao-automatica-do-runner.md`.** Registra:
  - a auto-atualização na recusa, com a pergunta, o `--auto-update` e as exceções
    (Mix, release, sem TTY);
  - a origem única com https (loopback como exceção);
  - o SHA-256 contra o `SHA256SUMS`, e por que isso não substitui uma assinatura (o
    `SHA256SUMS` vem do mesmo servidor e protege contra corrupção e download parcial,
    não contra um servidor comprometido; a assinatura fica como pendência);
  - a troca por arquivo temporário e `rename`;
  - a reexecução por `Port` com `:nouse_stdio` no terminal e pelo gerenciador no
    serviço, e o fallback;
  - a convenção do `download_url`, sem campo novo no protocolo;
  - o porquê da chave de teste do e2e.
- `docs/guias/instalacao.md`: na seção "Runner desatualizado", a pergunta, o `[S/n]`, o
  `--auto-update`, que `service install` já o usa (quem instalou o serviço antes precisa
  rodar `service install` de novo), sem permissão (o comando manual), e "a primeira
  atualização automática acontece no deploy seguinte".
- `docs/guias/deploy.md`: uma nota de que o `RUNNER_DOWNLOADS_URL` precisa ficar na
  mesma origem da plataforma para a auto-atualização funcionar.
- `docs/specs/protocolo-runner.md`: como descrito em "Protocolo".
- ADR 0023 e ADR 0020: sem edição de conteúdo; a nova ADR as cita.

## Riscos

- **Reexecução e TTY:** o `:nouse_stdio` herdando o terminal e o comportamento do
  Ctrl+C precisam ser verificados no binário real (macOS arm64 e Linux). O fallback
  ("rode de novo") está desenhado. Não há teste automático de TTY real no CI.
- **Detecção de TTY:** `:io.getopts(:standard_io)[:terminal]` sob `eval`/`-noshell`.
  Confirmar no OTP 28.5.0.6 do binário. Se não servir, a alternativa é
  `System.cmd("sh", ["-c", "test -t 0"])`, que não serve porque o filho não herda o
  stdin; nesse caso usar um `Port` com `:nouse_stdio` rodando `test -t 0`.
- **Ambiente herdado pelo filho:** se `RELEASE_*` ou `__BURRITO*` vazarem, o binário
  novo pode rodar o payload antigo. A lista de variáveis a remover vai ter teste.
- **Serviço em loop:** um runner instalado como serviço antes desta feature, sem
  `--auto-update`, continua saindo e o gerenciador o reinicia a cada 5 s (já acontece
  hoje). O guia manda reinstalar o serviço.
- **macOS:** o binário baixado pelo Req não ganha quarentena, então o Gatekeeper não
  bloqueia. O `rename` evita o problema de sobrescrever no lugar.
- **Disco no mesmo FS:** o temporário fica no mesmo diretório do binário, para o
  `rename` ser atômico (nunca em `/tmp`).
- **Migrações e dados:** nenhum.
- **Concorrência:** dois runners com o mesmo binário atualizando juntos. Cada um usa um
  temporário próprio e o `rename` é atômico; o último vence com o mesmo conteúdo. É
  aceitável.
- **Cobertura:** `relaunch` no modo serviço chama `System.halt`. Isolar o halt numa
  função injetável para o resto ser testado; nada de exclusão de cobertura.
- **Dialyzer:** os specs de `handle/2` e `install/2` com tipos de erro explícitos.
  `Output.fail!/1` é `no_return`, então o retorno precisa ficar coerente nos ramos
  dos comandos. Possível necessidade de `:crypto` em `extra_applications` ou no PLT.
- **Credo:** `Update.handle/2` tende a crescer. Separar a decisão (pura) da execução.
