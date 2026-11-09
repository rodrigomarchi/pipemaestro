# Etapa 2 — Testes que falham

## O que foi escrito

`apps/pipe_maestro_protocol/test/pipe_maestro_protocol/version/image_build_test.exs`
(`PipeMaestroProtocol.Version.ImageBuildTest`, `async: true`, `:tmp_dir`).

O plano previa verificar o Makefile só à mão. Aqui ele vira teste automatizado sem
Docker e sem compilar nada: cada teste roda o `make` de verdade na raiz do checkout,
com dois executáveis falsos no começo do `PATH`, num `tmp_dir`:

- **`mix` falso**: imprime `FAKE_CP_OUT` (ou `FAKE_RUNNER_OUT`, quando os argumentos têm
  `runner.version`) e sai com `FAKE_CP_STATUS` / `FAKE_RUNNER_STATUS`. Simula a compilação
  quebrada, a saída com ruído de compilação e qualquer versão, inclusive vazia e
  `dev+unknown`.
- **`docker` falso**: só anota os argumentos em `docker.log`. O teste confere se o
  `docker build` rodou e com quais `--build-arg`.

`CP_VERSION`, `RUNNER_VERSION`, `MAKEFLAGS` e `MAKELEVEL` são removidos do ambiente do
`make`, via a opção `env:` de `System.cmd`, sem tocar o ambiente global da VM.

O teste fica no `protocol` porque é a app do esquema de versão
(`PipeMaestroProtocol.Version`), e o vizinho `version/git_test.exs` já testa o cálculo
pelo git.

| Grupo | Critério do plano | Casos |
|---|---|---|
| `make image with versions in the scheme` | 2 | release pura, `…+dev.<sha>` e `dev+<sha>`: sai 0, imprime as duas versões, um `docker build` com `--build-arg CP_VERSION=…`, `RUNNER_VERSION=…` e `-t pipemaestro`. Usa a última linha quando o `mix` imprime antes o que compila |
| `make image when a version cannot be computed` | 1 | `mix` com status 1 no control plane e no runner: sai ≠ 0 com `Não consegui calcular a versão do control plane` / `do runner`, mostra a saída do `mix` e não chama o `docker` |
| `make image with a version outside the scheme` | 3 | para cada lado: `""`, `dev+unknown`, `2026-11-04.01+dev.unknown`, linha de erro, `2026-11-4.01`, `2026-11-04.1`, `0.1.0` e `dev+ABC123`. Sai ≠ 0, a mensagem diz qual versão falhou e o `docker` não roda |
| `the version targets` | 1 | `cp.version` e `runner.version` saem ≠ 0 quando o `mix` falha. `cp.version` imprime só a última linha quando o `mix` passa |
| `the Makefile's version expressions` | 6 | a expressão da data (`[0-9]{4}-[0-9]{2}-[0-9]{2}`) aparece uma única vez no Makefile, compartilhada pelo `image` e pelo `runner.release` |
| `the Dockerfile` | 4, 5 | há `ARG ALLOW_UNVERSIONED`. No estágio `build`, antes do `RUN mix compile`, um `RUN` checa `ALLOW_UNVERSIONED`, `CP_VERSION` e `RUNNER_VERSION`, cita `make image` e sai com `exit 1` |

Os testes do Dockerfile são estruturais, porque o build real leva minutos e precisa de
Docker. A prova de comportamento dos critérios 4 e 5 (`docker build` sem os
argumentos, e com `ALLOW_UNVERSIONED=1` gerando `dev+unknown`) continua manual, na etapa
de implementação, como diz o plano.

## Execução

```
cd apps/pipe_maestro_protocol && mix test test/pipe_maestro_protocol/version/image_build_test.exs
Result: 3/28 passed
Failed: 25 tests
```

### Por que cada falha é a esperada

- **Versões válidas** (3 testes): `assert output =~ "2026-11-04.01+dev.abc1234"` com
  `left: ""`. O `image` atual não imprime as versões antes de construir; com `-s`, a
  saída fica vazia. O `docker` falso até roda, então não é erro de setup.
- **Cálculo falhando** (2 testes): `assert status != 0` com `left: 0`. É exatamente o bug
  da tarefa: o `| tail -n 1` e o `$(...)` engolem o status, e o `docker build` roda.
- **Fora do esquema** (16 testes): `assert status != 0` com `left: 0`. Hoje o `image` não
  valida nada e aceita `""`, `dev+unknown`, uma linha de erro etc.
- **Alvos de versão** (2 testes): `cp.version fails when mix fails` e
  `runner.version fails when mix fails`, com `assert status != 0`, `left: 0`, pelo
  `tail -n 1`.
- **Dockerfile** (2 testes): `assert dockerfile =~ ~r/^ARG ALLOW_UNVERSIONED/m` falha, e
  `no RUN in the build stage checks ALLOW_UNVERSIONED before mix compile`. O argumento e
  a checagem ainda não existem.

### Os 3 que já passam (de propósito)

- `takes the last line mix prints, after what it compiles` e
  `cp.version prints only the last line when mix succeeds` documentam o comportamento
  que a implementação **não pode** perder: o `tail -n 1` sobre a saída do `mix`.
- `the release expression is written once…`: hoje a expressão aparece só no
  `runner.release`. A implementação vai movê-la para uma variável e usá-la nos dois
  alvos. O teste impede que alguém a copie para o `image`.

### Vizinhos

- `mix test test/pipe_maestro_protocol/version/git_test.exs test/pipe_maestro_protocol/version_test.exs`
  → `39 passed`.
- `mix format --check-formatted` → ok.
- `mix credo --strict` no arquivo novo → `found no issues`.

## Para a etapa de implementação

- A mensagem de valor fora do esquema precisa conter `versão do control plane` ou
  `versão do runner`, em minúsculas: o teste procura esses trechos. A de falha de
  cálculo precisa de `Não consegui calcular a versão do control plane` / `do runner`, e
  da saída do `mix`.
- O `docker build` precisa receber `--build-arg CP_VERSION=<v>` e
  `--build-arg RUNNER_VERSION=<v>` como argumentos separados, nessa forma, mais
  `-t pipemaestro`.
- No Dockerfile, a checagem é um `RUN` próprio no estágio `build`, antes de
  `RUN mix compile`, contendo `ALLOW_UNVERSIONED`, `CP_VERSION`, `RUNNER_VERSION`,
  `make image` e `exit 1`.
