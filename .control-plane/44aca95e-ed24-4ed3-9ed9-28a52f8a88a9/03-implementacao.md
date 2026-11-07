# Implementação: etapa que continua a sessão da etapa anterior

O plano (`01-plano.md`) foi implementado. Os 23 testes da etapa anterior passam sem
mudança: nenhum foi enfraquecido nem corrigido. Acrescentei um teste, o da sessão
retomada na auditoria do job, que a etapa anterior tinha deixado de fora.

## O que mudou, por app

### `apps/pipe_maestro_protocol`
- `Job`: dois campos opcionais. `persist_session` é booleano. `resume_session_id` tem
  de 1 a 100 bytes, no formato `^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$`. Um job com
  `scratch` e `resume_session_id` é recusado. O `@moduledoc` descreve os dois campos
  e o `session_resumed` do `job:finished`.
- `Hello.capabilities/0` passa a incluir `"resume_session"`.
- A versão do protocolo não sobe, porque a mudança só acrescenta campos.

### `apps/pipe_maestro_runner`
- `Claude.argv/1`:
  - com `resume_session_id`, passa `--resume <id> --fork-session`;
  - com `persist_session`, não passa nenhuma flag de sessão;
  - sem os dois, continua passando `--no-session-persistence`.
- `JobRunner`:
  - O estado do job guarda `path` e `resume`, que vale `:none`, `:requested` ou
    `:fell_back`.
  - Quando o CLI termina com erro antes da linha `system` (sem cancelamento nem
    estouro de tempo), o job roda de novo uma vez, sem `--resume`, pelo novo
    `open_port/5`. Ele usa o mesmo diretório e o mesmo prompt, sem refazer o setup.
  - O `seq` dos eventos continua contando. O tempo limite da nova execução é o que
    sobrou do original.
  - O `job:finished` traz `session_resumed` (`true` ou `false`) só quando o job pediu
    retomada.
- Runner antigo: ele não anuncia a capacidade, então o control plane não manda os
  campos. Se os campos chegarem mesmo assim, `Job.new/1` de uma versão antiga ignora
  chaves desconhecidas e a etapa roda do zero.

### `apps/pipe_maestro` (domínio)
- `Stage`:
  - novo campo `context`, `"fresh"` por padrão; um valor vazio também vira `"fresh"`;
  - `contexts/0`;
  - um valor desconhecido é recusado com "escolha como a etapa começa".
- `Pipeline.validate_contexts/1` põe o erro no `context` da própria etapa em três
  casos: a primeira etapa, uma etapa em grupo e uma etapa depois de um grupo. As
  etapas removidas pelo formulário (`action: :replace`) não contam como anterior.
- `Yaml` exporta `context` só quando é `"continue"` e o lê na importação.
  `PipelineKind.pipeline_schema/0` aceita `context` nas propostas do agente.
- `Tasks`:
  - `session_context/3` só age se o runner da tarefa tiver a capacidade
    `"resume_session"`.
  - O job leva `persist_session` quando a etapa seguinte é `"continue"`.
  - Uma etapa `"continue"` leva `resume_session_id`: o `session_id` da última
    tentativa aprovada da etapa anterior, inclusive numa segunda tentativa.
- `Jobs.Job` ganha `session_resumed`, com a migração
  `20261120100000_add_session_resumed_to_jobs.exs` (coluna nula, sem backfill).

### `apps/pipe_maestro_web`
- Formulário (`form_fields.ex`, `form.ex`):
  - o seletor "Contexto" (`stage-context-<i>`) fica no bloco "Avançado", feito com
    `icon_field type="select"`;
  - o `<summary>` desse bloco ganha `data-testid="stage-advanced-<i>"`;
  - o `<details>` abre sozinho quando o `context` tem erro.
- `TaskComponents.stage_run_session/1` mostra um badge do Petal na tentativa
  (`stage-run-session-<key>-<attempt>`): "Continuou a etapa anterior" ou "Começou do
  zero: a sessão anterior não estava disponível". O selo aparece em `TaskLive.Show`.
- Na auditoria do job, o fato "Retomou a sessão" mostra o id retomado e diz quando
  ele estava indisponível. Coberto por um teste novo em `job_live_test.exs`.

### Documentação
- `docs/adr/0041-continuar-a-sessao-da-etapa-anterior.md`.
- A ADR 0004 aponta para a 0041.
- `docs/specs/protocolo-runner.md` descreve a capacidade, os dois campos do job e
  `session_resumed`.

## Decisões tomadas na implementação
- "Em grupo" quer dizer `group` preenchido. O editor já desfaz o grupo de uma etapa
  sozinha, então não há outro caso a tratar.
- Na nova execução sem sessão, o stderr da tentativa que falhou é descartado: o
  relatório final mostra o da execução que valeu.
- `job_context/3` ficou complexa demais para o Credo; os campos de sessão foram para
  `session_context/3`.

## Como verificar
- `make ci.quick > /tmp/ciq.log 2>&1; echo $?` → `0`. Resultados: protocolo 105/105,
  domínio 518/518, web 465/465, runner 225/225, cobertura acima de 60% em todos.
- `make e2e` → 30/30, incluindo `tests/pipeline-stage-context.spec.ts`.
- `make e2e.shots FILE=tests/pipeline-stage-context.spec.ts`: capturas claras e
  escuras conferidas. O seletor e o erro em vermelho aparecem no bloco "Avançado"
  aberto da etapa 1.
- O `make ci` completo, com Dialyzer, não rodou nesta etapa.
