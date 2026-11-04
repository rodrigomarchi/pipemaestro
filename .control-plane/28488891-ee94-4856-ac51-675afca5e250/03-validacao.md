# Validação (make ci e e2e)

## Por que a tentativa anterior falhou

O gate `mix test --warnings-as-errors --cover` saiu com código 2 logo depois de
`==> pipe_maestro_protocol / Cover compiling modules ...` e imprimiu o uso do CLI
`pipemaestro`. Os testes não falharam: a VM do `mix test` se comportou como o CLI do runner.

- O runner instalado é um binário Burrito, que exporta `__BURRITO` (com `RELEASE_ROOT`, `ROOTDIR` e
  `BINDIR`). `PipeMaestroRunner.Shell.run/3` roda os comandos de setup e de gate sem limpar o
  ambiente, então o `mix test` do gate herda `__BURRITO`.
- `PipeMaestroRunner.Application.standalone/2` tratava qualquer VM com `__BURRITO` como o binário.
  Ao carregar o app do runner, ela chamava `Main.run/1` com os argumentos do `mix`, imprimia o uso
  e fazia `System.halt(2)`.
- A sessão do agente não tem `__BURRITO`, porque `Claude.env/2` já a remove. Por isso o `make ci`
  passou no agente e falhou no gate.
- Reprodução: `__BURRITO=1 mix test --warnings-as-errors --cover` sai com código 2 e mostra
  exatamente a saída do gate. Sem a variável, o comando passou 6 vezes seguidas.

O problema não vem do merge. Ele vale para qualquer gate que rode a suíte deste repositório pelo
runner em binário. Mesmo assim, o gate desta tarefa só passa com a correção.

## Correções (commit `a137c00`)

| Arquivo | Mudança | Motivo |
|---|---|---|
| `apps/pipe_maestro_runner/lib/pipe_maestro_runner/application.ex` | `standalone/2` só roda o comando quando `RELEASE_ROOT` é igual a `:code.root_dir()`, ou seja, quando a VM é o próprio release. A raiz pode ser injetada com a opção `:root_dir` | Uma VM do Mix que só herdou as variáveis (o `mix test` do gate, que roda sob o runner instalado) não executa mais o CLI. Esta é a correção que faz o gate atual passar. |
| `apps/pipe_maestro_runner/lib/pipe_maestro_runner/shell.ex` | `Port.open` com `{:env, [{~c"__BURRITO", false}]}` | Ataca a causa: os comandos de setup e de gate deixam de herdar `__BURRITO`, como `Claude.env/2` já fazia. Só vale depois que o runner com esta mudança for instalado. |
| `apps/pipe_maestro_runner/test/pipe_maestro_runner/application_test.exs` | O teste do binário passa `RELEASE_ROOT`/`root_dir`. Novo teste: com as variáveis apenas herdadas, nada roda | Cobre a nova condição. |
| `apps/pipe_maestro_runner/test/pipe_maestro_runner/shell_test.exs` (novo) | Status e saída de `Shell.run`. `__BURRITO` não chega ao comando | Cobre a remoção da variável. |

Não usei nenhum `@dialyzer` ignore, `credo:disable`, skip ou exclusão de cobertura.

## Resultados

- `__BURRITO=1 mix test --warnings-as-errors --cover` (o ambiente do gate): **exit 0**. Protocol
  tem 76 testes, pipe_maestro 241, web 263 e runner 166, sem falhas.
- `make ci > /tmp/ci-28488891.log 2>&1`: **exit 0**. O compile não deu warnings. Format e
  deps.unlock passaram, o credo não achou problemas e o dialyzer terminou com `Total errors: 0`.
  Cobertura por app: protocol 93.07%, pipe_maestro 92.98%, web 95.12%, runner 81.48%.
- `make e2e`: não rodei de novo. As correções só tocam `apps/pipe_maestro_runner`, e nada em
  `pipe_maestro_web`, `assets/` ou `e2e/` mudou desde a tentativa anterior, em que ele passou
  (20 de 20).

## Commits desta etapa

- `a137c00` Corrige a integração com a main: mix test de um gate não sobe como o CLI do runner
