# Implementação: qualidade das entregas no Uso

O plano (`01-plano.md`) está implementado e os testes da etapa 2 passam.

**Verificação:**
- `make ci.quick`: saída 0 (protocol 113, domínio 625, web 545, runner 284 testes; cobertura
  acima de 60% em todos os apps).
- `mix dialyzer`: 0 erros.
- `make e2e FILE=tests/usage-quality.spec.ts`: passa.
- `make e2e.shots`: claro e escuro conferidos. Estão em `$CP_FILES_DIR/screenshots/`.

## O que mudou, por app

### `apps/pipe_maestro` (domínio)

**Migrações**
- `20261124100000_create_integration_pr_outcomes`: a tabela do desfecho, única por tarefa,
  com um índice parcial do que a reconciliação ainda consulta.
- `20261124100100_add_origin_to_decisions`: a coluna `decisions.origin`.
  - As correções antigas são preenchidas: `auto_merge` onde `decided_via` é
    "merge automático", e `person` no resto.

**`Integrations.PrOutcome`** (schema novo)
- `classify/1` devolve `:accepted_clean`, `:accepted_changed`, `:closed` ou `:open`.

**`Integrations.PrOutcomes`** (módulo novo)
- `ready/1`: cria o desfecho na primeira vez que a tarefa termina com PR. `ready_at` nunca
  muda depois.
- `merged/2` e `closed/2`: só alteram um desfecho ainda aberto, então o mesmo evento
  repetido não muda nada.
- `reviewed?/2` e `review_round/2`: um `UPDATE` atômico que conta cada review uma vez.
- `observe/1`: lê os commits do PR e separa os do pipeline dos de uma pessoa, um por tarefa
  de cada vez (`:global.trans`).
  - Quando a head do pipeline é nova e está na lista, os commits até ela são do pipeline e
    os seguintes são de uma pessoa.
  - Fora disso, todo SHA que não é do pipeline é de uma pessoa.
  - Commits de merge (mais de um pai) não contam.
- `pending_task_ids/0` e `reconcile/1`: consultam `get_pr/3` para registrar o merge ou
  fechamento que o webhook perdeu, depois chamam `observe/1`.
- Uma falha do host vai para `commits_error`. Nada levanta exceção.

**Providers**
- `Provider` ganhou a callback `pr_commits/3`, implementada em `GitHub` e `Forgejo` com
  todas as páginas.
- `ProviderSupport.pr_commit/1` normaliza cada commit.
- `get_pr/3` e `Event.pr` passam a trazer `merged_at` e `closed_at`.

**`Conversation`**
- Merge: grava o desfecho e faz a leitura final dos commits na hora.
- PR fechado sem merge: passa a ser `processed` e grava `closed`. Nada mais dispara.
- Correção por review:
  - recebe `origin: :review`;
  - incrementa as rodadas;
  - o mesmo review processado de novo fica `ignored`, "review já aplicado". A chave é o id
    do review, ou o id da entrega original sem o prefixo `replay:`.

**Outros pontos de chamada**
- `AutoMerge`: o merge grava o desfecho; a correção recebe `origin: :auto_merge`.
- `Reconciler`: passo novo, `outcomes`, que conta os PRs encontrados integrados ou fechados.
- `Feedback.write_pr`: chama `ready/1`, porque o PR pode ser aberto depois do fim da tarefa.
- `FeedbackWorker`: chama `observe/1` depois de cada sincronização.
- `Tasks`: `finish/2` chama `PrOutcomes.ready/1`, e `correct/3` aceita `:origin` (padrão
  `:person`).
- `Tasks.Decision`: campo `origin`.

**`Usage.quality/3`**
- Aceitação no total, por pipeline e por semana. O período conta pelo `ready_at`, e o tempo
  até o merge é a mediana (`percentile_cont`).
- Retrabalho por etapa, com as "Correção N" agrupadas em `correcao`.
- `top_pauses`.
- Mesmos filtros de `report/3` (`"pipeline"`, `"project_id"`).

### `apps/pipe_maestro_web`

- `PipeMaestroWeb.UsageQualityComponents` (novo) monta a aba:
  - cartões das taxas;
  - linha com PRs entregues, mediana até o merge e rodadas de review por PR;
  - tabela por pipeline;
  - barras por semana;
  - tabela de retrabalho por etapa (matriz de números, então `.table`, como diz o ADR 0052);
  - etapas que mais pausam, em `record_list`/`record_card`;
  - estado vazio.
- `UsageLive`:
  - aba `qualidade`;
  - select de projeto na barra (`usage-project`), que vale para todas as abas, porque
    `report/3` e `Insights` já aceitavam `project_id`;
  - o rótulo do período cita o projeto filtrado;
  - só delega para `Usage`.

### `apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`

Não mudam. O protocolo e os Channels continuam iguais.

### Documentação

- `docs/adr/0053-qualidade-das-entregas.md`: o modelo do desfecho, o critério de commit
  humano e as limitações aceitas.
- `docs/specs/integracoes.md`:
  - §1 ganha o `PrOutcome`;
  - §2 registra `merged_at`/`closed_at` no evento;
  - §7 descreve o PR fechado sem merge e o review repetido;
  - §8 é nova: o desfecho do PR e `pr_commits/3`, com os endpoints.
- `AGENTS.md`: as linhas de `Usage` e `Integrations` descrevem a parte nova.

## Testes que ajustei, e por quê

Nenhum foi enfraquecido. Os problemas estavam nos dados ou na forma do teste:

- **`conversation_test.exs`:** o setup punha o `finished_at` uma hora atrás, mas o payload
  de merge é de 2026-11-05. O teste "tempo até o merge > 0" comparava um merge anterior ao
  `ready_at`. O setup agora usa `finished_at: ~U[2026-11-04 10:00:00Z]`, antes do merge.
- **`pr_outcomes_test.exs` (`classify/1`):** na etapa 2, as structs viraram mapas para
  compilar sem o módulo. `classify/1` recebe a struct, então as structs voltaram.
- **`auto_merge_test.exs`:** o helper `waiting/2` não preenchia `finished_at`, e o teste
  comparava `ready_at` com `nil`. Ele agora passa `finished_at`.
- **`quality_test.exs`:** `+0.0` no padrão, para não gerar o aviso de `0.0` sob
  `--warnings-as-errors`.
- **`auto_merge_test.exs` e `reconciler_test.exs`:** removi aliases `PrOutcome` sem uso.

## Como verificar

```bash
cd apps/pipe_maestro && mix test test/pipe_maestro/integrations test/pipe_maestro/usage
cd apps/pipe_maestro_web && mix test test/pipe_maestro_web/live/usage_live_test.exs
make e2e FILE=tests/usage-quality.spec.ts
make e2e.shots FILE=tests/usage-quality.spec.ts   # imagens em e2e/screenshots/usage-quality/
```

Na tela: Uso e limites → aba **Qualidade** (`?aba=qualidade`). Os filtros de pipeline,
projeto e período ficam na barra do topo.
