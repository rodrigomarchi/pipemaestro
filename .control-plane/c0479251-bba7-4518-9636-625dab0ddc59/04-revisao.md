# Etapa 4 — Revisão de convenções

Revisado o diff de `origin/main` até a branch (código, testes, migração, web, config, docs).

## O que a revisão achou e corrigiu

1. **Critério 1 do plano sem cumprir.** O ADR 0053 e as atualizações de spec estavam
   pendentes desde a etapa 3. Escritos:
   - `docs/adr/0053-fontes-de-tarefa.md`: o behaviour e suas responsabilidades, o `Item` e a
     `Origin`, o registro por chave, fonte ≠ host git, fonte → projeto, o destino de
     `issue_feedback` e `pending_issue_comment`, a migração e o que fica fora;
   - `docs/specs/integracoes.md`: o modelo da tarefa com a origem, a seção da fonte
     `git_issue`, o passo de criação (`TaskSources.start/3`) e os comandos comuns;
   - `docs/specs/maquina-de-estados-tarefa.md`: "Origem numa fonte";
   - `docs/adr/0036-integracoes-com-hosts-git.md`: relação com o 0053 no cabeçalho.
2. **Contagem na prosa** (`AGENTS.md`): o `@moduledoc` de `TaskSources.Source` dizia "four
   responsibilities". Trocado por uma frase sem número.
3. **Docs com linha longa** em `Conversation` e `AutoMergeWorker` (apontavam para os módulos
   novos): reajustadas.

## O que conferi e está certo

- **Critério 3**: `grep` por `LinkedRepo|Trigger|IssueState|IssueUrl|html_url|issue[` e
  `issue_url|issue_number|pending_issue` em `tasks.ex` e `tasks/*.ex` sai vazio.
- **`@spec` e `@moduledoc`** em tudo o que é novo (`TaskSources`, `Source`, `Item`, `Origin`,
  `Commands`, `Dispatcher`, `IssueSource`, migração, `Integrations.pull_request_keeper/1`,
  `Proposals.origin_url/1`).
- **Sem `handle_info` que engole mensagem**: o `Dispatcher` trata só `{:source_task_updated, _}`
  e o `GenServer` registra o resto.
- **Fronteiras**: o web chama só `TaskSources` e `Proposals`; o runner só ganhou a correção do
  cache de gates (etapa 3), sem dependência nova; o `protocol` não muda, e a entrega ao runner
  mantém as mesmas chaves, então runner antigo segue compatível.
- **Telas**: só mudam o campo lido (`source_url`) e o helper de link; rótulos, markup e
  `data-testid` iguais. Sem Tailwind novo, sem teste de e2e novo.
- **Cobertura**: nenhuma exclusão acrescentada.
- **Compatibilidade de dados**: a migração é idempotente e mantém as colunas antigas; as
  propostas antigas são lidas por `Origin.from_input/1` e por `triaging?/3`.
- **Critérios 2, 4 e 5**: testes em `issue_source_test.exs`, `task_sources_test.exs`
  (fonte fictícia) e `origin_backfill_test.exs`.

## Verificação

Mudaram só documentação e comentários de módulo (compilação com `--warnings-as-errors` e
`mix format --check-formatted` limpos). Nenhuma suíte foi rodada: a árvore de código é a que
passou no `make ci.quick` da etapa 3.
