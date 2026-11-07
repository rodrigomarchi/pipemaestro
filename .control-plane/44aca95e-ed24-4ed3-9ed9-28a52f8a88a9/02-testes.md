# Testes que falham: etapa que continua a sessão da etapa anterior

Só foram escritos testes, o CLI falso e o Page Object (infraestrutura de teste).
Nenhum código de produção mudou. `mix format` rodou. Na suíte inteira (`mix test`
a partir da raiz) falham **só os 23 testes novos**: 2 no protocolo, 11 no domínio,
6 na web e 4 no runner. Os testes que já existiam passam.

## Arquivos

| Arquivo | O que descreve |
|---|---|
| `apps/pipe_maestro/test/pipe_maestro/pipelines_test.exs` | `describe "stage context"`: `"fresh"` por padrão e `Stage.contexts/0`; `"continue"` aceito numa etapa comum; contexto desconhecido recusado ("escolha como a etapa começa"); os três casos recusados, cada um com o erro no `context` da etapa (a primeira etapa, uma etapa em grupo, uma etapa depois de um grupo); YAML de ida e volta (`context: "continue"` exportado, `"fresh"` omitido; YAML sem o campo → `"fresh"`) |
| `apps/pipe_maestro/test/pipe_maestro/tasks_test.exs` | `describe "a stage that continues the previous stage's session"`: pipeline a/b(continue)/c; runner com `"resume_session"`: job de `a` com `persist_session`, job de `b` com `resume_session_id = "sessao-a"`, inclusive na 2ª tentativa depois de uma falha; `c` sem nenhum dos dois campos. Runner sem a capacidade → nenhum campo. Etapa anterior sem `session_id` → sem `resume_session_id` |
| `apps/pipe_maestro/test/pipe_maestro/jobs_test.exs` | `finish_job` grava `session_resumed` (`false`), e o valor volta em `get_job!` |
| `apps/pipe_maestro_protocol/test/pipe_maestro_protocol/job_test.exs` | `persist_session` e `resume_session_id` passam pela ida e volta `to_map`/`from_map`; são recusados: booleano inválido, id vazio, com `/` ou `..`, com espaço, com mais de 100 bytes ou que não é texto; `scratch` com `resume_session_id` também é recusado |
| `apps/pipe_maestro_protocol/test/pipe_maestro_protocol_test.exs` | `"resume_session" in Hello.capabilities()` |
| `apps/pipe_maestro_runner/test/pipe_maestro_runner/job_runner_test.exs` | `Claude.argv`: com `persist_session`, sem `--no-session-persistence` e sem `--resume`; com `resume_session_id`, `--resume <id> --fork-session` em sequência. `describe "continuing the previous stage's session"` usa o CLI falso: (1) a retomada passa `--resume/--fork-session` e termina com `session_resumed: true`; (2) a sessão `ausente-1` → uma nova execução sem `--resume` (e, com `persist_session`, sem `--no-session-persistence`), `succeeded`, `session_resumed: false`, `seq` contínuo; (3) uma falha depois de retomar (`[falha]` sai após a linha `system`) não relança: `failed`, `session_resumed: true`; (4) um job que não pede retomada não tem `session_resumed` (guarda de regressão, já passa) |
| `apps/pipe_maestro_runner/test/support/fake_claude` | Com `FAKE_CLAUDE_ARGS_FILE` (no `env` do job), grava o argv, um por linha. Com `--resume ausente*`, escreve "No conversation found with session ID: …" no stderr e sai 1 antes de qualquer linha no stdout |
| `apps/pipe_maestro_web/test/pipe_maestro_web/live/pipeline_live_test.exs` | `describe "the stage's context"`: o seletor `stage-context-0` com a opção "Continuar a etapa anterior"; a 1ª etapa com `continue` mostra o erro e nada é salvo; na edição, a etapa 1 com `continue` é salva e o formulário reaberto mostra `continue` selecionado |
| `apps/pipe_maestro_web/test/pipe_maestro_web/components/task_components_test.exs` | `TaskComponents.stage_run_session/1` (`run` com `job` carregado), com o test id `stage-run-session-<key>-<attempt>`: "Continuou a etapa anterior" (`session_resumed` `true` ou `nil` com `resume_session_id`); "Começou do zero: a sessão anterior não estava disponível" (`false`); nada sem pedido de retomada ou sem job |
| `e2e/tests/pipeline-stage-context.spec.ts` | Fluxo A: em "Refatoração", a etapa 0 com `continue` mostra o erro no `stage-card-0` (com screenshot); depois a etapa 1 com `continue` é salva, e a edição reaberta mostra `fresh`/`continue` |
| `e2e/pages/PipelinesPage.ts` | `openAdvanced(i)` (clica em `stage-advanced-<i>`, o `<summary>` do bloco "Avançado", que a implementação precisa marcar com esse test id), `stageContext(i)` e `stageCard(i)` |

Decisões que os testes fixam para a implementação:
- o componente do selo chama-se `TaskComponents.stage_run_session/1`, com `attr :run`;
- o `<summary>` do bloco "Avançado" da etapa ganha `data-testid="stage-advanced-<index>"`;
- o selo usa o test id `stage-run-session-<key>-<attempt>`, no padrão de `stage-run-status-…`.

Ficou de fora dos testes: o fact "Retomou a sessão" na auditoria (`audit_components.ex`
não tem teste de componente; fica para a implementação cobrir em `job_live_test` se
quiser) e o cancelamento durante a retomada. Neste segundo caso, o CLI falso com
`[lento]` já abre a sessão antes de dormir, então não haveria relançamento de
qualquer forma; o caso (3) cobre a regra "depois da linha `system` não relança".

## Por que cada teste falha (e por que é a falha esperada)

### Protocolo (`mix test apps/pipe_maestro_protocol/test`: 103/105)

```
1) test Hello capabilities: none by default, validated, deduplicated and sorted
   Assertion with in failed
   left:  "resume_session"
   right: ["doctor", "git_credential", "health", "logs", "scratch"]

2) test Job keeps the CLI's session for the next stage, or resumes the previous stage's
   Assertion with == failed
   code:  assert Map.get(keep, :persist_session) == true
   left:  nil
```
A capacidade ainda não existe e `Job.new/1` ignora as chaves que não conhece.
O teste usa `Map.get/2`, e não `%Job{persist_session: …}`, para compilar antes do
campo existir. O compilador avisa (`incompatible types given to Map.get/2`), e o
aviso some quando o campo existir.

### Domínio (`pipelines_test`, `jobs_test`, `tasks_test`: 126/137 nos três arquivos)

```
stage context a stage starts fresh by default / a plain stage may continue the previous one
   ** (KeyError) key :context not found in: %PipeMaestro.Pipelines.Stage{...}
   (+ warning: PipeMaestro.Pipelines.Stage.contexts/0 is undefined or private)

stage context rejects an unknown context / the first stage has nothing to continue / a stage in a group may not continue
   match (=) failed
   left:  {:error, changeset}
   right: {:ok, %PipeMaestro.Pipelines.Pipeline{...}}

stage context a stage after a group may not continue it
   left:  [nil, nil, ["a etapa anterior roda em paralelo: não há uma sessão só para continuar"]]
   right: [nil, nil, nil]

stage context the context survives YAML, and a YAML without it starts fresh
   Assertion with =~ failed
   code:  assert yaml =~ "context: \"continue\""

what a run reports for auditing the outcome keeps whether the run resumed the previous stage's session
   code:  assert Map.get(job, :session_resumed) == false
   left:  nil

a stage that continues ... the stage before keeps its session and the stage resumes it, also on a new attempt
a stage that continues ... with no session from the stage before, the stage runs fresh
   code:  assert first.context["persist_session"] == true
   left:  nil

a stage that continues ... a runner that cannot resume runs every stage fresh
   ** (KeyError) key :context not found in: %PipeMaestro.Pipelines.Stage{...}
```
`Stage` ainda não tem o campo `context` (o `cast` descarta o valor, então o pipeline
é salvo quando deveria ser recusado). `Yaml` não exporta o campo. `Job` não grava
`session_resumed`. `Tasks.job_context/3` não monta `persist_session` nem
`resume_session_id`. (No caso "a stage after a group", o `{:error, _}` vem do
pipeline começar com um grupo, que já é recusado hoje; a falha esperada é a
ausência do erro no `context`.)

### Runner (`job_runner_test.exs`: 43/47)

```
Claude argv keeps the session for the next stage, or resumes the previous one
   Refute with in failed
   code:  refute "--no-session-persistence" in argv

continuing ... a job that resumes a session forks it and says so
continuing ... a run that fails after resuming is not run again
   code:  assert finished["session_resumed"] == true
   left:  nil

continuing ... a session the CLI does not have: the job runs again fresh, once
   code:  assert finished["session_resumed"] == false
   left:  nil
```
`Claude.argv/1` sempre passa `--no-session-persistence`, e o `Job` do protocolo
ainda descarta `resume_session_id`, então o CLI falso nem recebe `--resume`, e o
`job:finished` não traz `session_resumed`. A suíte inteira do runner (221/225)
mostra que a mudança no CLI falso não quebrou nenhum teste antigo.

### Web (`task_components_test`, `pipeline_live_test`: 30/36)

```
stage_run_session/1 (4 testes)
   ** (UndefinedFunctionError) function PipeMaestroWeb.TaskComponents.stage_run_session/1 is undefined or private

the stage's context the first stage cannot continue one before it
   Expected truthy, got false
   code: assert has_element?(view, "[data-testid=stage-context-0]")

the stage's context a later stage continues the one before, and the form shows it again
   ** (ArgumentError) could not find non-disabled input, select or textarea with name "pipeline[stages][1][context]"
```
O componente e o seletor ainda não existem.

### Playwright

`make e2e.typecheck`: passa (código de saída 0).
`make e2e FILE=tests/pipeline-stage-context.spec.ts`: falha onde devia:
```
TimeoutError: locator.click: Timeout 10000ms exceeded.
  - waiting for getByTestId('stage-advanced-0')
```
O `<summary>` do bloco "Avançado" ainda não tem o test id, e o seletor de contexto
ainda não existe.

## Suíte completa

`mix test` (raiz): protocolo 103/105, domínio 507/518, web 458/464, runner 221/225.
As 23 falhas são exatamente os testes listados acima.
