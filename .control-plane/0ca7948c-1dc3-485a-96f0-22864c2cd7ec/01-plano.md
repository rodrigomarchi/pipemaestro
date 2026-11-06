# Plano: atualização automática como padrão do runner (`--no-auto-update` desliga)

Base: `origin/main` em `ee53154` (a branch já estava em dia; nenhum commit fora desta tarefa).

## Entendimento

Hoje (`docs/adr/0025-atualizacao-automatica-do-runner.md`), quando a plataforma recusa o
binário único por versão (`"outdated"`, no `login` ou em qualquer join),
`PipeMaestroRunner.Update.handle/2` só atualiza sem perguntar com `auto_update: true`. Sem a
opção, ele pergunta `[S/n]` num terminal e, sem terminal, mostra `Update.message/1` e sai.

Com esta mudança, **atualizar passa a ser o padrão** do binário único:

| Situação | `opts[:auto_update]` | Comportamento |
|---|---|---|
| Binário único, opção omitida, com terminal | `nil` | atualiza sem perguntar, `relaunch` em `:interactive` |
| Binário único, opção omitida, sem terminal | `nil` | atualiza sem perguntar, `relaunch` em `:service` |
| Binário único com `--auto-update` | `true` | igual ao padrão (segue aceito: serviços instalados gravam `start --auto-update`) |
| Binário único com `--no-auto-update`, com terminal | `false` | pergunta `Baixar e instalar a versão X agora? [S/n]` |
| Binário único com `--no-auto-update`, sem terminal | `false` | `Update.message/1` e sai, sem baixar |
| Sob Mix / release sem Burrito | qualquer | `Update.message/1` (inalterado) |

Inalterados: validação de origem (`SelfUpdate.urls/3`), SHA-256, troca atômica,
mensagem de "sem permissão de escrita" (`Update.manual/2`) e `relaunch`.

### Critérios de aceite verificáveis

1. Binário único desatualizado: `start` e `login` sem opção atualizam sem perguntar, com e sem terminal → testes de `Update` com `:auto_update` omitido.
2. `--no-auto-update` restaura a pergunta (terminal) e a mensagem (sem terminal) → testes existentes de `Update`, renomeados como cenário `--no-auto-update`.
3. `--auto-update` continua aceito sem "Opção inválida" → `runner_tasks_test.exs`.
4. `pipemaestro service install` (binário único) grava `start` sem `--auto-update` → `service_test.exs` (launchd e systemd).
5. Nenhum texto de uso ou documento trata `--auto-update` como necessário → `main_test.exs` + revisão dos docs listados abaixo (`grep -rn "auto-update"`).
6. `make ci` e `make e2e` verdes, com o Flow E usando `--no-auto-update`.

## Mudanças por app

### `apps/pipe_maestro` (domínio)
Não muda.

### `apps/pipe_maestro_web`
Não muda (nenhuma tela, Channel ou payload; a tela Executores não menciona `--auto-update`).

### `apps/pipe_maestro_protocol`
Não muda.

### `apps/pipe_maestro_runner`
- `lib/pipe_maestro_runner/update.ex`
  - `consent/2`: `opts[:auto_update] == false` é o único caminho para a pergunta/mensagem;
    qualquer outro valor (`nil` ou `true`) → `{:ok, if(opts[:tty?], do: :interactive, else: :service)}`.
    Forma sugerida:
    ```elixir
    cond do
      opts[:auto_update] != false -> {:ok, if(opts[:tty?], do: :interactive, else: :service)}
      opts[:tty?] != true -> :refused
      yes?(opts[:gets].(prompt(refusal))) -> {:ok, :interactive}
      true -> :refused
    end
    ```
  - `@moduledoc` e `@doc` de `handle/2`: atualizar sem perguntar é o padrão; `auto_update: false`
    (`--no-auto-update`) pergunta no terminal e, sem terminal, dá a mensagem; documentar que
    `:auto_update` omitido equivale a `true`.
- `lib/pipe_maestro_runner/commands/start.ex` e `commands/login.ex`: o switch
  `auto_update: :boolean` fica (o `OptionParser` já aceita `--no-auto-update` → `false`, e
  omitido → `nil`, que já é repassado como está em `opts[:auto_update]`; nenhuma mudança de lógica).
  Atualizar `@moduledoc` e linhas de uso para `[--no-auto-update]`.
- `lib/pipe_maestro_runner/main.ex`: uso de `login` e `start` com `[--no-auto-update]`.
- `lib/pipe_maestro_runner/service.ex`: `program(%{"__BURRITO_BIN_PATH" => bin})` →
  `{[bin, "start"], Path.dirname(bin)}`; ajustar o `@doc` (atualizar é o padrão do binário único).
- `lib/mix/tasks/runner.start.ex` / `runner.login.ex`: só conferir os `@moduledoc` (hoje não
  mencionam a opção; sob Mix não há atualização).

## Fronteiras

Toda a mudança fica no runner e não introduz dependência nova: o runner continua dependendo
só de `pipe_maestro_protocol`; o domínio continua sem web.

## Protocolo

**Não toca** `apps/pipe_maestro_protocol` nem o formato das mensagens dos Channels; o payload
de recusa `"outdated"` (`version`, `runner_version`, `download_url`) é o mesmo.
`protocol_version` não sobe. Runners antigos: recebem o mesmo payload e se comportam como
antes (um runner da ADR 0025 sem a opção continua perguntando; serviços instalados com
`start --auto-update` continuam atualizando, e com a nova versão a opção segue aceita).
Em `docs/specs/protocolo-runner.md` muda só o texto do comportamento do runner
("sem terminal e sem `--auto-update`" → "com `--no-auto-update` e sem terminal, ou
recusando a pergunta").

## Telas

Nenhuma tela muda. E2E (que roda o runner pelo Mix):
- `config/e2e.exs` força `tty?: true` e um `__BURRITO_BIN_PATH` falso (`:update_prompt`).
  Com o novo padrão, sem opção o runner tentaria atualizar no e2e. Por isso, em
  `e2e/tests/runner-connection.spec.ts`, **os dois** passos do Flow E precisam de
  `--no-auto-update`:
  - linha ~55: `runner.start("runner.login", ["--url", platform, "--no-auto-update"])`;
  - linha ~79: `runner.start("runner.start", ["--no-auto-update"])` (a tarefa cita só o
    `login`, mas o `start` desatualizado também responde "n" à pergunta e quebraria sem a opção).
- Comentário de `config :pipe_maestro_runner, :update_prompt` em `config/e2e.exs`: dizer
  que o runner pergunta como um binário único num terminal *com `--no-auto-update`*, e que
  sem a opção ele tentaria atualizar (as specs passam a opção e respondem "não").
- Nenhum `data-testid` novo; sem componentes Petal.

## Testes

- `test/pipe_maestro_runner/update_test.exs`
  - O setup mantém `auto_update: false`: renomear os testes de pergunta ("answering …",
    "Ctrl+D", "without a terminal…") para deixar explícito o cenário `--no-auto-update`.
  - Novos: `:auto_update` omitido (`Keyword.delete(opts, :auto_update)`) e `tty?: false` →
    `:relaunched`, binário novo, `{:relaunch, _, @argv, :service}`, sem `{:asked, _}`.
    Omitido e `tty?: true` → `:relaunched`, `:interactive`, sem perguntar.
  - Manter os de `--auto-update` (compatibilidade).
  - "under Mix or a release": cobrir também a opção omitida (e `false`), continuando a mensagem
    e sem downloads.
- `test/pipe_maestro_runner/service_test.exs`: `program/1` do binário único →
  `{["/opt/cp/pipemaestro", "start"], "/opt/cp"}`; plist e unit sem `--auto-update`
  (`refute =~ "--auto-update"`, `ExecStart=/opt/cp/pipemaestro start\n`).
- `test/pipe_maestro_runner/main_test.exs`: o uso lista `--no-auto-update` (e `--version`).
- `test/mix/tasks/runner_tasks_test.exs`: `start` e `login` aceitam `--no-auto-update` e
  `--auto-update` (falham pelo motivo esperado, não por "Opção inválida").
- `self_update_test.exs:234` usa `["start", "--auto-update"]` só como argv de exemplo: pode ficar.
- E2E: Flow E ajustado (acima); `make e2e`.

## Documentação

- **Nova ADR** `docs/adr/0038-atualizacao-automatica-por-padrao.md` (0037 é a última):
  contexto (issue #20; o padrão de perguntar exige intervenção e sem terminal nada acontece),
  decisão (atualizar é o padrão no binário único, com e sem terminal; `--no-auto-update`
  desliga e restaura pergunta/mensagem; `--auto-update` aceito por compatibilidade com
  serviços já instalados; `service install` grava só `start`; Mix/release inalterados;
  e2e passa `--no-auto-update`), consequências (serviços antigos continuam funcionando sem
  reinstalar; quem quiser controle manual usa a opção; `protocol_version` não sobe).
- **ADR 0025**: linha de status/nota "alterada pela [ADR 0038]" e ajuste do trecho da
  chave de teste do e2e se necessário (sem reescrever a decisão histórica).
- `docs/guias/instalacao.md`, seção "Runner desatualizado": o padrão atualiza sem perguntar;
  `--no-auto-update` pergunta no terminal e sem terminal mostra a mensagem; o serviço grava
  `start` e atualiza por padrão (serviços antigos com `start --auto-update` seguem valendo,
  sem reinstalar).
- `docs/specs/protocolo-runner.md` (~linha 66): "Fora disso (sob Mix, ou com
  `--no-auto-update` sem terminal ou recusando a pergunta)…".
- `docs/plano/03-roadmap-orquestrador.md` (~linha 219): trocar "`--auto-update` para serviços"
  por "por padrão; `--no-auto-update` para perguntar" e citar a ADR 0038.

## Riscos

- **Migrações/dados**: nenhum.
- **Comportamento silencioso**: o binário passa a baixar e trocar o executável sem
  confirmação. Mitigado pelas mesmas garantias da ADR 0025 (origem, https, SHA-256, troca
  atômica) e pela opção de desligar. Registrar na ADR.
- **E2E**: esquecer `--no-auto-update` em um dos dois passos do Flow E faria o runner tentar
  baixar de verdade do servidor de e2e (ou falhar) em vez de perguntar — por isso os dois.
- **Concorrência**: nenhuma nova.
- **Cobertura**: só ganha testes.
- **Dialyzer**: `consent/2` mantém o mesmo tipo de retorno; sem risco.
