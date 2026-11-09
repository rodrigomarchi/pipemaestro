# Etapa 7 — Documentação e resumo

## Documentos

- **ADR novo:** [`docs/adr/0053-fontes-de-tarefa.md`](../../docs/adr/0053-fontes-de-tarefa.md), no índice de `docs/README.md`.
- **Atualizados:**
  - `docs/specs/integracoes.md`: a origem na tarefa, a seção da fonte `git_issue`, o passo de criação e os comandos comuns;
  - `docs/specs/maquina-de-estados-tarefa.md`: "Origem numa fonte";
  - `docs/adr/0036-integracoes-com-hosts-git.md`: relação com o 0053.
- **Sem mudança:** `docs/specs/protocolo-runner.md` (o protocolo não mudou), `docs/guias/*`,
  `e2e/README.md` (nenhuma tela nem `data-testid` novo) e o roadmap em `docs/plano/`.

## Resumo para quem revisa

**O que mudou e por quê.** A fonte da tarefa (de onde ela vem) deixou de estar misturada ao
host git (onde fica o código). É uma refatoração sem mudança visível.

- **`apps/pipe_maestro`**
  - Contexto novo `PipeMaestro.TaskSources`: o behaviour `Source`, as structs `Item` e
    `Origin`, `Commands` (movido de `Integrations`), o `Dispatcher` (no lugar do
    `FeedbackWorker`) e o registro de fontes por chave em `config/config.exs`.
  - `Integrations.IssueSource` implementa o behaviour para as issues do Forgejo e do GitHub,
    reaproveitando `Ingest`, `Reconciler`, `Feedback`, `Conversation` e `AutoMerge`.
  - O motor (`tasks.ex`, `tasks/task.ex`) e `Proposals` não referenciam mais `LinkedRepo`,
    `Trigger`, `IssueState` nem o JSON da issue. A tarefa guarda `source`, `source_id`,
    `source_url`, `source_ref` e `pending_source_note`; quem cuida do PR é decidido por
    `Integrations.pull_request_keeper/1`.
  - Migração `AddTaskSource` (em `apps/pipe_maestro/priv/repo/migrations/`): preenche a
    origem das tarefas existentes e mantém as colunas antigas.
- **`apps/pipe_maestro_web`**: o formulário usa o campo `source_url`, os links leem a origem
  nova e os webhooks entram pela fonte `git_issue`. Aparência, rótulos e `data-testid` iguais.
- **`apps/pipe_maestro_protocol`**: não muda.
- **`apps/pipe_maestro_runner`**: sem mudança de comportamento do protocolo. Só uma correção
  do cache de gates (`GateCache`, ver riscos).

**Protocolo.** Não mudou, e a versão não sobe. A entrega de uma etapa ao runner tem as mesmas
chaves (`push`, `pr`, `status`, `issue_comment`); só muda quem calcula o `issue_comment` (a
fonte). Runner antigo continua compatível, sem tratamento.

**Riscos e o que olhar com mais atenção**

1. **Migração e deploy.** O deploy migra antes de subir a versão nova; as colunas antigas
   (`issue_url`, `issue_number`, `pending_issue_comment`) ficam para a versão em execução
   nesse intervalo. Tarefas criadas depois não as preenchem, então um rollback do código as
   veria sem `issue_url`. Removê-las é uma migração posterior.
2. **Propostas em andamento.** O input antigo (`issue_url`, `linked_repo_id`, `issue_number`)
   é lido como origem `git_issue` (`Origin.from_input/1`, `Proposals.triaging?/3`).
3. **Correção no runner, que sobe a versão dele (ADR 0035).** `PipeMaestroRunner.GateCache`
   copiava o índice do git com um mtime novo, e um arquivo regravado no mesmo segundo e com
   o mesmo tamanho parecia inalterado: o gate saía do cache sobre código que mudou. A cópia
   agora mantém o mtime do índice. Os runners se atualizam uma vez por causa disso.
4. **`issue_feedback`** continua com esse nome e é de `Integrations` (também guarda o estado
   do PR que o auto-merge lê). Separá-lo pediria reescrever `Feedback.sync/1`; ficou fora.
5. **Testes instáveis corrigidos no caminho:** `GatesTest` (runner, duas vezes) e
   `CredentialsTest` (fila do sandbox, em `config/test.exs`).

**Como verificar**

```
make ci                                         # compile, format, credo, testes com cobertura, dialyzer
make e2e                                        # suíte inteira
make e2e FILE="tests/integrations-issue-to-task.spec.ts tests/task-pipeline.spec.ts"
grep -nE "LinkedRepo|Trigger|IssueState|IssueUrl|html_url|issue_url|issue_number|pending_issue" \
  apps/pipe_maestro/lib/pipe_maestro/tasks.ex apps/pipe_maestro/lib/pipe_maestro/tasks/*.ex   # vazio
```

Passos manuais: abrir uma tarefa criada de uma issue e conferir o link "Issue" no painel;
criar uma tarefa à mão com um link de issue; abrir uma proposta triada de uma issue. Em
todos, a aparência é a de antes.

Resultados registrados: `make ci` (etapa 5) e `make e2e` (etapa 6) saíram 0.
