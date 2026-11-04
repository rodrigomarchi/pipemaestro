# 01 — Entendimento e plano: versão do runner no formato AAAA-MM-DD.NN

## 0. O que existe hoje (lido no código)

- `ClaudeControlPlaneRunner.Host.runner_version/0` devolve o `vsn` da app (`"0.1.0"`) e vai no
  `Hello` (`runner_version`), validado em `ClaudeControlPlaneProtocol.Hello` por `text/2`:
  string de **1 a 120 bytes**. A coluna `runners.runner_version` é `:string` (varchar 255).
  O formato novo mais longo (`2026-11-04.12+dev.abc1234`, ~25 bytes) cabe com folga: **sem
  migration e sem mudança no protocolo**.
- A versão já aparece crua em `runners_live.ex:157` (lista), `runner_live.ex:121` (cabeçalho do
  card da página do runner), `board_live.ex:370`, `backoffice/workspace_live/show.ex:279` e
  `activate_runner_live.ex:123` — sem `data-testid`.
- `mix.exs` (raiz): a release Burrito `cp_runner` usa `binary_version/0` = `0.1.0+<sha curto>`.
- **`make runner.release` já existe**: gera a release Mix `claude_control_plane_runner` em
  `_build/prod/rel`, e `make runner.install` depende dele. O pedido reaproveita o nome para outra
  coisa (tag + binário). Decisão tomada (ver §2.6): o alvo atual passa a se chamar
  `runner.rel`, `runner.install` passa a depender de `runner.rel`, e `runner.release` ganha o
  significado do pedido.
- `ClaudeControlPlaneRunner.Main` despacha `login|start|status|logout|doctor|service`; qualquer
  outra coisa imprime o uso e sai com 2. O binário Burrito passa pelo mesmo `Main.run/1`
  (`Application.standalone/2`).
- `.dockerignore` exclui `.git`: a imagem do control plane não enxerga as tags.
- O layout `app` não tem rodapé de página; tem o `<:footer>` da sidebar (botão de sair). O
  layout `public` tem `<footer>`; o `backoffice` tem `<:footer>` da sidebar.
- e2e: `runner-connection.spec.ts` roda o runner de verdade com `mix runner.*` (MIX_ENV=e2e)
  via `helpers/runnerProcess.ts`.

## 1. Especificação

### 1.1 O esquema

- **Versão de release**: `AAAA-MM-DD.NN` — data local da máquina que fez a release e um
  sequencial de dois dígitos que recomeça em `01` a cada dia (`2026-11-04.01`,
  `2026-11-04.02`, `2026-11-05.01`). Acima de `99` o número cresce sem padding extra (`100`);
  a comparação é sempre numérica.
- **Fonte de verdade**: tag git anotada `runner-AAAA-MM-DD.NN`. Uma única série de tags para o
  repositório (runner e control plane saem do mesmo commit/umbrella).
- **Build com tag no HEAD** → a versão da tag (se houver mais de uma no HEAD, a maior).
- **Build sem tag no HEAD** (dev, testes, `mix runner.*`) → `<última versão>+dev.<sha curto>`,
  onde "última versão" é a maior tag `runner-*` **alcançável a partir do HEAD**
  (`git tag --merged HEAD`); sem nenhuma tag → `dev+<sha curto>`.
- Sem git ou sem repositório (ex.: build fora do checkout) → `dev+unknown`.
- **Override de compilação**: a variável `CP_VERSION`, se definida na compilação, é usada como
  está (necessária para a imagem Docker, que não tem `.git`, e para o e2e fixar versões).
- Tags de outros formatos (`v1.2.3`, `runner-2026-11-04`, `runner-2026-13-40.01`,
  `runner-2026-11-04.1`, `runner-2026-11-04.01-rc`) são ignoradas em todo cálculo.
- A versão é **embutida na compilação** (atributo de módulo) e o módulo se recompila quando o
  valor calculado muda (`__mix_recompile__?/0`), então um novo commit/tag aparece sem `--force`.
- A versão do Mix/Burrito continua semver por baixo: `0.1.0+<versão sanitizada>.<timestamp>`
  no binário, para que cada build tenha uma versão Burrito diferente (o binário se desempacota
  uma vez por versão). Nada exibido usa essa string.

### 1.2 `make runner.release`

1. Recusa se a árvore de trabalho tiver mudanças (`git status --porcelain` não vazio) — o
   binário tem de corresponder ao commit da tag.
2. Recusa se o HEAD já tiver uma tag `runner-*` (evita duas versões no mesmo commit; imprime a
   existente).
3. Calcula a próxima versão a partir das tags do dia (data local): `mix runner.version --next`.
4. Cria a tag anotada `runner-<versão>` (`git tag -a ... -m "Runner <versão>"`).
5. Roda `make runner.binary` (aceita `TARGET=`); como o HEAD agora tem a tag, o binário embute a
   versão. Se o build falhar, a tag fica (local, não publicada) e a mensagem diz como apagá-la
   (`git tag -d runner-<versão>`).
6. Não faz push; ao final imprime `git push origin runner-<versão>`.

### 1.3 CLI do runner

- `cp-runner --version` e `cp-runner version` imprimem **só** a versão (uma linha), saem com 0.
  Em dev: `mix runner.version` (mesmo comando). `mix runner.version --next` imprime a próxima
  versão de release (usado pelo Makefile; não exposto no binário).
- `cp-runner start`: a primeira linha é `cp-runner <versão>`.
- `cp-runner status` e `cp-runner doctor`: uma linha `Versão: <versão>` (no doctor, como item
  informativo `✓ versão: <versão>`).
- O uso (`cp-runner` sem comando) passa a listar `--version`.

### 1.4 Control plane

- Exibe a própria versão (mesmo cálculo, compilada na app de domínio) no rodapé: no `<:footer>`
  da sidebar dos layouts `app` e `backoffice` e no `<footer>` do layout `public`
  (`data-testid="app-version"`). "Rodapé do layout" é interpretado assim porque o layout `app`
  não tem rodapé de página.
- Versão do runner visível, com `data-testid`, na lista de executores e no cabeçalho da página do
  runner (o texto corrido atual vira um elemento próprio).
- **Selo "desatualizado"** (badge Petal, `color="warning"`) na lista e na página do runner quando:
  a versão do runner é uma **release pura** (`AAAA-MM-DD.NN`, sem `+dev`) **e** a versão do
  control plane tem uma base de release (release pura, ou `X+dev.sha` com base `X`) **e**
  runner < base do control plane, comparando data e depois NN.
  - Runner dev (`...+dev.sha`, `dev+sha`) → nunca marcado.
  - Runner em formato antigo/desconhecido (`0.1.0`) ou sem versão → não marcado (mostrado como
    está).
  - Control plane `dev+sha` (sem tag alguma) → ninguém é marcado.
  - Runner igual ou mais novo que o control plane → não marcado.
- Board, backoffice e tela de ativação continuam mostrando a versão como texto (sem selo; fora do
  escopo pedido).

### 1.5 Critérios de aceite

1. A função pura de próxima versão cobre: primeiro do dia → `.01`; incremento `.01→.02`;
   virada de dia (ontem `.05`, hoje → `.01`); tags de outros formatos ignoradas; `.09→.10` e
   `.10 > .09`.
2. Num repositório git temporário: sem tag → `dev+<sha>`; tag no HEAD → a versão; commit depois
   da tag → `<tag>+dev.<sha>`; tag não alcançável não conta. Nenhuma tag criada neste repo.
3. `cp-runner --version`/`version` imprimem só a versão; `start` a mostra na primeira linha;
   `status` e `doctor` a mostram.
4. O Hello leva a versão nova; versões até 120 bytes continuam aceitas, as antigas também.
5. Lista e página do runner mostram a versão e o selo segundo §1.4; o rodapé mostra a versão do
   control plane.
6. `make runner.release` cria a tag anotada, gera o binário com a versão e imprime o comando de
   push; recusa árvore suja e HEAD já com tag.
7. `make ci` e `make e2e` verdes; capturas claro/escuro das telas tocadas.

## 2. Plano

### 2.1 Fronteiras

| App | O que entra |
|---|---|
| `claude_control_plane_protocol` | `ClaudeControlPlaneProtocol.Version`: o formato é contrato entre runner e control plane (os dois o calculam e o control plane compara o que o runner manda). Funções puras + a leitura do git (build-time), única app que runner e domínio compartilham. |
| `claude_control_plane_runner` | Versão embutida, comando `version`, linhas em start/status/doctor, `mix runner.version [--next]`. |
| `claude_control_plane` (domínio) | Versão do control plane embutida; `Runners.outdated?/1` (delegando à comparação do protocolo). |
| `claude_control_plane_web` | Rodapé, versão + selo na lista e na página do runner. Sem lógica: chama o domínio. |

Nenhuma mudança de `protocol_version`, de mensagens ou de schema do banco.

### 2.2 Arquivos

**Protocolo**
- `apps/claude_control_plane_protocol/lib/claude_control_plane_protocol/version.ex` (novo) —
  puro, com `@spec`/`@moduledoc`:
  - `parse(String.t()) :: {:release, Date.t(), pos_integer()} | {:dev, base | nil, sha} | :unknown`
  - `parse_tag(String.t()) :: {:ok, {Date.t(), pos_integer()}} | :error` (só `runner-AAAA-MM-DD.NN`, data válida, NN ≥ 01 com ao menos 2 dígitos)
  - `next([tag], Date.t()) :: String.t()`
  - `describe(head_tags :: [String.t()], reachable_tags :: [String.t()], sha :: String.t() | nil) :: String.t()`
  - `compare(a, b) :: :lt | :eq | :gt` (releases)
  - `outdated?(runner_version :: String.t() | nil, reference_version :: String.t()) :: boolean()`
  - `format(Date.t(), pos_integer()) :: String.t()`
- `apps/claude_control_plane_protocol/lib/claude_control_plane_protocol/version/git.ex` (novo) —
  I/O de git com diretório explícito (`System.cmd("git", ["-C", dir, ...])`):
  `current(dir)` (`CP_VERSION` ou `describe` com `tag --points-at HEAD`,
  `tag --merged HEAD --list 'runner-*'`, `rev-parse --short HEAD`), `next(dir, date)`,
  `local_today/0` (`:calendar.local_time/0`). Falha de git → `dev+unknown`.

**Runner**
- `lib/claude_control_plane_runner/version.ex` (novo) — `@version Git.current(<raiz do repo>)`
  em compilação, `version/0`, `__mix_recompile__?/0` (recompila quando o valor mudaria).
- `host.ex` — `runner_version/0` passa a devolver `Version.version/0`.
- `main.ex` — `run(["--version"])`/`run(["version"])` → `IO.puts` e 0; moduledoc com o uso.
- `commands/version.ex` (novo) — o comando (imprime a versão; `--next` imprime a próxima).
- `commands/start.ex` — primeira linha `cp-runner <versão>`.
- `commands/status.ex`, `commands/doctor.ex` (e `doctor.ex` se o item morar lá) — linha da versão.
- `lib/mix/tasks/runner.version.ex` (novo) — `mix runner.version [--next]` via `CLI.run/2`.

**Domínio**
- `lib/claude_control_plane/version.ex` (novo) — mesma mecânica do runner, para o control plane.
- `lib/claude_control_plane/runners.ex` — `outdated?(Runner.t()) :: boolean()`.

**Web**
- `components/layouts.ex` — componente `app_version` nos três rodapés.
- Componente do selo (`runner_version`/`outdated_badge`) junto do `runner_status` existente
  (mesmo módulo de componentes), com `<.badge color="warning" variant="soft" label="desatualizado">`.
- `live/runners_live.ex` — versão em elemento próprio + selo.
- `live/runner_live.ex` — idem no cabeçalho do card.

**Build e operação**
- `Makefile` — `runner.rel` (ex-`runner.release`), `runner.install: runner.rel`, novo
  `runner.release` (§1.2), `image` passa `--build-arg CP_VERSION=$(mix runner.version)`; lista
  `.PHONY` atualizada.
- `Dockerfile` — `ARG CP_VERSION` / `ENV CP_VERSION` antes do `mix compile`/`release`.
- `mix.exs` (raiz) — `binary_version/0` → `0.1.0+<versão sanitizada para build metadata>.<timestamp UTC>`
  (calcula com `git` como hoje; não pode chamar módulos das apps).
- `e2e` — `playwright.config.ts` (webServer) e Makefile `e2e*` exportam `CP_VERSION=2026-11-04.02`
  para o servidor; `helpers/runnerProcess.ts` aceita `version` e o passa como `CP_VERSION` ao
  `mix runner.*` (cada app só recompila o seu módulo de versão; o runner usa sempre o mesmo valor
  nas specs que fixam versão, para não alternar recompilações).

### 2.3 Ordem

1. Protocolo: `Version` puro + testes; `Version.Git` + testes com repo temporário.
2. Runner: `Version`, `Host`, `Main`, comandos, Mix task + testes.
3. Domínio: `ClaudeControlPlane.Version`, `Runners.outdated?/1` + testes.
4. Web: componentes, rodapé, lista e página + testes LiveView.
5. Makefile/mix.exs/Dockerfile (`runner.rel`, `runner.release`, `image`, `binary_version`).
6. e2e: spec, page object, capturas claro/escuro (`make e2e.shots`).
7. Docs (§4). `make ci` e `make e2e`.

### 2.4 Migrations

Nenhuma.

### 2.5 Protocolo runner ↔ control plane

Sem mudança de mensagem nem de `protocol_version`: `runner_version` continua string de 1..120
bytes. Só a spec documenta o formato esperado (informativo; formatos antigos seguem aceitos).

### 2.6 Decisões tomadas sem perguntar

- Renomear o `runner.release` atual para `runner.rel` (o pedido exige o nome).
- "Última versão" do build dev = maior tag alcançável do HEAD.
- Rodapé = sidebar footer (`app`, `backoffice`) + footer do `public`.
- Recusar árvore suja e HEAD já com tag em `runner.release`.
- Versões não reconhecidas não recebem selo.
- `CP_VERSION` como override de compilação (Docker sem `.git`, e2e).

## 3. Testes por camada

**Protocolo (ExUnit)**
- `version_test.exs`: `next/2` — primeiro do dia, incremento, virada de dia, tags ignoradas
  (`v1.2.3`, `runner-2026-11-04`, `runner-2026-11-04.1`, `runner-2026-13-01.01`,
  `runner-2026-11-04.01-rc`, `foo-2026-11-04.01`), `.09→.10`, lacunas (`.01,.03` → `.04`);
  `describe/3` — tag no HEAD, várias no HEAD (maior), dev com base, `dev+sha`, sha nil;
  `compare/2` por data e depois NN (inclui `.10 > .09`, `2026-11-05.01 > 2026-11-04.99`);
  `outdated?/2` — anterior marcado, igual/mais novo não, runner dev nunca, `0.1.0`/nil não,
  CP `X+dev` usa base `X`, CP `dev+sha` nunca marca.
- `version/git_test.exs`: repo em `System.tmp_dir!` (`git init`, commits com `-c user.*`,
  `git tag -a`): sem tag; tag no HEAD; commit após tag; tag num branch não alcançável; `next`
  com tags do dia; `CP_VERSION` sobrepõe; diretório sem git → `dev+unknown`. `on_exit` apaga.
- `claude_control_plane_protocol_test.exs`/Hello: versão no formato novo aceita; 121 bytes
  recusada.

**Runner (ExUnit)**
- `host_test.exs`: o teste atual (`~r/^\d+\.\d+\.\d+/`) muda para o formato novo
  (`AAAA-MM-DD.NN(+dev.sha)?|dev+sha`).
- `main_test.exs`: `--version` e `version` imprimem só a versão (capture_io) e devolvem 0; uso
  lista `--version`.
- Testes de `start`/`status`/`doctor` existentes ganham a asserção da linha de versão (start: a
  primeira linha).
- `runner.version` task: imprime a versão; `--next` imprime algo no formato de release.

**Domínio (ExUnit)**
- `version_test.exs` do control plane: formato válido.
- `runners_test.exs`: `outdated?/1` com runner release antigo/igual/dev/legado, com a versão de
  referência injetável (opção ou função com a referência como argumento) para não depender do
  git do build.

**Web (ExUnit/LiveView)**
- `runners_live_test.exs`: `runner-version-<nome>` mostra a versão; `runner-outdated-<nome>`
  presente para release antiga, ausente para dev/igual.
- `runner_live_test.exs`: `runner-detail-version` e `runner-detail-outdated` idem.
- Layout: `app-version` no shell do app, no backoffice e no público.

**e2e (Playwright)** — `runner-connection.spec.ts`, Flow B:
- servidor com `CP_VERSION=2026-11-04.02`; runner iniciado com `CP_VERSION=2026-11-04.01`;
- `runner-version-<nome>` = `2026-11-04.01` e `runner-outdated-<nome>` visível na lista;
  `runner-detail-version` e `runner-detail-outdated` na página do runner;
  `app-version` = `2026-11-04.02`; saída do CLI começa com `cp-runner 2026-11-04.01`.
- As demais specs (`job-execution`, `task-pipeline`) seguem sem versão fixa (runner dev, sem
  selo) — se a alternância de recompilação do módulo de versão do runner pesar, fixar a versão
  em todas via `RunnerProcess`.
- Capturas `runner-online` e `runner-detail-*` em claro e escuro com o selo.
- Novos `data-testid`: `app-version`, `runner-version-<nome>`, `runner-outdated-<nome>`,
  `runner-detail-version`, `runner-detail-outdated`. Atualizar `pages/RunnersPage.ts` e a
  anotação `@flow B` da spec.

**Makefile `runner.release`**: não testado em ExUnit (efeito em git e Burrito); a lógica que ele
usa (`next`) é a função pura testada. Conferência manual descrita no guia.

## 4. Documentação

- **ADR novo** `docs/adr/0016-esquema-de-versao.md`: formato, tag como fonte de verdade,
  dev `+dev.sha`, embutida na compilação com `CP_VERSION` de override, semver Burrito por baixo,
  regra do selo, por que no protocolo. Listar em `docs/README.md`.
- `docs/guias/instalacao.md`: seção "Versões e releases do runner" — a regra, `make
  runner.release` (passos, recusas, push manual), `cp-runner --version`, o selo, `runner.rel` /
  `runner.install`, `CP_VERSION` na imagem.
- `docs/specs/protocolo-runner.md`: exemplo do Hello com `"runner_version": "2026-11-04.01"` e
  nota do formato (informativo, sem mudança de versão do protocolo).
- `docs/adr/0013`: a menção a `runner.install` continua válida; ajustar se citar o
  `runner.release` antigo.
- `docs/plano/03-roadmap-orquestrador.md` Marco 5 (Distribuição): registrar a versão do runner.
- `e2e/README.md`, se listar os test ids/fluxos.

## 5. Riscos

- **Recompilação por valor**: `__mix_recompile__?/0` roda git a cada `mix compile`; custo pequeno,
  mas precisa existir em compile-time (CI sem `.git` cai em `dev+unknown`, não quebra).
- **Docker sem `.git`**: sem `--build-arg CP_VERSION` a imagem mostra `dev+unknown` e ninguém é
  marcado — `make image` passa o argumento; quem builda fora do Makefile precisa saber (guia).
- **Runner e control plane de commits diferentes**: o selo compara releases; um control plane
  implantado de commit sem tag usa a base alcançável — pode marcar como desatualizado um runner da
  mesma base? Não: igual não marca. Mas um control plane implantado de um commit **posterior** a
  uma tag mais nova que o runner marcará — é o comportamento desejado.
- **Data local**: duas máquinas em fusos diferentes podem gerar a mesma data; a sequência vem das
  tags locais — quem não fez `git fetch --tags` pode recriar uma tag já publicada. O guia orienta
  `git fetch --tags` antes; o push falharia em caso de colisão (tag já existe no remoto).
- **Rename de `runner.release`**: quem tem o hábito do alvo antigo receberá tag + binário; mitigado
  pelas recusas (árvore suja/HEAD com tag) e pela doc.
- **e2e e `_build/e2e` compartilhado**: servidor e runner compilam no mesmo build dir com valores
  de `CP_VERSION` diferentes; cada módulo de versão é de uma app distinta, mas specs que alternam
  versões do runner causam recompilação do módulo do runner entre specs.
- **Timestamp na versão Burrito**: cada build desempacota um payload novo no cache do usuário
  (acúmulo em disco); aceitável e alinhado ao pedido ("muda a cada build").
- **Dialyzer**: o atributo calculado em compile-time tem de ter tipo estável (`String.t()`); sem
  ignores.
