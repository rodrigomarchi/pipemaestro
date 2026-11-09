# Etapa 7 — Documentação e resumo

Esta etapa não mudou `apps/`. Os documentos foram escritos junto da implementação e conferidos aqui.

## Documentos

- **ADR novo:** `docs/adr/0053-retencao-por-workspace.md`, no índice de `docs/README.md`.
  Registra as políticas e os padrões, o que conta como metadado, o resumo gravado antes da poda, o
  marcador `events_pruned_at`, a poda do conteúdo do anexo, a cota com lock por workspace e o 413
  `quota_exceeded`.
- **ADR 0042:** a consequência "Ainda não há retenção nem cota" aponta para o ADR 0053.
- **`docs/plano/01-visao-arquitetura.md`:** a restrição de retenção e a questão em aberto 3 estão
  marcadas como respondidas pelo ADR 0053.
- **`docs/specs/protocolo-runner.md` §4.8:** nova resposta `413 quota_exceeded` na tabela do `PUT`.
- **`docs/guias/deploy.md` e `docs/guias/instalacao.md`:** o `client_max_body_size 12m;` está correto para
  anexos de até 10 MiB, e uma recusa por cota não é o 413 do nginx: vem do app, com o corpo
  `quota_exceeded`.
- `docs/guias/ui-petal.md`, `docs/guias/phoenix.md` e `e2e/README.md` não precisaram mudar: as telas usam
  os componentes e as convenções que já estão descritos neles.

## Resumo para quem revisa

### O que mudou e por quê

O control plane guardava anexos e eventos do agente sem escolha do cliente. Agora cada workspace define,
no backoffice, a retenção dos dois.

- **`apps/pipe_maestro`:**
  - os campos `job_files_retention_days`, `job_files_quota_mib`, `agent_events_retention_days` e
    `agent_events_after_retention` no workspace, com validação em português e uma migração;
  - `Jobs.Files` ganha a cota no upload (lock por workspace, recusa contada em `files_refused_quota`),
    `workspace_usage/1` e `prune/2`;
  - `Maintenance` poda por workspace: os eventos ficam só com os metadados (`Event.metadata_keys/0`) ou
    são apagados, a telemetria sai e o job é marcado em `events_pruned_at`;
  - `Insights.store_summary/1` não regrava o resumo de um job podado.
- **`apps/pipe_maestro_web`:**
  - o upload além da cota responde 413 `quota_exceeded`, e o download de um anexo podado responde 410;
  - a tentativa da etapa avisa os arquivos recusados e os eventos podados;
  - o anexo podado aparece com o nome e "removido pela retenção";
  - o backoffice edita as políticas e mostra o uso contra a cota, e a tela de Uso mostra o mesmo aos
    membros, abaixo do conteúdo principal.
- **`apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`:** não mudaram.

### Protocolo e runners antigos

O formato das mensagens e a versão do protocolo não mudaram. O `PUT` de arquivos ganhou uma resposta (413
`quota_exceeded`), que é um 4xx: runners antigos e novos não repetem o envio e contam o arquivo em
`files_failed`, e o job termina como terminaria. O control plane distingue a recusa por cota pela própria
contagem (`files_refused_quota`).

### Riscos e o que olhar com mais atenção

- **Padrão novo dos eventos:** depois de 30 dias os eventos passam a ficar só com os metadados, em vez de
  sumir. É o pedido da tarefa, mas o banco guarda mais linhas (pequenas). Um workspace escolhe `delete`
  para o comportamento antigo.
- **Migração:** marca como podados os jobs que a poda global antiga já esvaziou, para a primeira execução
  não regravar o resumo deles. Confira o `UPDATE` do backfill em um banco com histórico.
- **Lista de chaves de metadado:** além das chaves pedidas, ficam `model`, `num_turns`, `pre_tokens`,
  `attempt` e `max_retries` (números e identificadores, sem conteúdo). Confirme se a lista serve.
- **Concorrência da cota:** um `pg_advisory_xact_lock` por workspace, dentro da transação que já trava o
  job. Não há teste automático de duas requisições simultâneas, porque no sandbox do Ecto os dois processos
  dividem a conexão e o lock seria reentrante. Vale ler `Jobs.Files.within_quota/3`.
- **`files_failed` e recusas:** o runner conta as recusas por cota em `files_failed`, e a tela desconta
  `files_refused_quota` para não avisar duas vezes.
- **Fora do que foi feito:** o uso por workspace não aparece no card da listagem do backoffice (só no
  detalhe); a edição pelo próprio cliente, a cobrança e o object storage ficam de fora, como pedido.
- **Testes intermitentes sem relação com a tarefa**, vistos durante o trabalho:
  `Integrations.CredentialsTest`, `PipeMaestroRunner.GatesTest` e `IntegrationLiveTest`. Todos passam
  isolados.

### Como verificar

- `make ci` (compile, format, credo, testes com cobertura e dialyzer).
- `make e2e FILE=tests/task-files-retention.spec.ts`, e `make e2e` para a suíte inteira.
- `make e2e.shots FILE=tests/task-files-retention.spec.ts` para as screenshots, claras e escuras.
- Passos manuais:
  1. No backoffice, edite um workspace e defina uma cota de 1 MiB, 30 dias de anexos e 30 dias de eventos.
     O detalhe do workspace mostra o uso contra a cota.
  2. Rode uma tarefa cujo agente deixe arquivos em `CP_FILES_DIR` além da cota. A tentativa mostra "N
     arquivos recusados", e a tarefa termina.
  3. Envelheça os dados e rode `PipeMaestro.Maintenance.run(DateTime.utc_now())`. Os anexos mostram
     "removido pela retenção", o download responde 410, e os passos da etapa mostram o aviso de conteúdo
     removido.
  4. Em `/w/<slug>/usage`, o bloco "Anexos e retenção" mostra o mesmo uso e as políticas.

As screenshots estão em `$CP_FILES_DIR/screenshots/`.
