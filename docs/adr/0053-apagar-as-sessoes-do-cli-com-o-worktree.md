# 0053 — As sessões do CLI saem com o worktree da tarefa

- **Status:** aceita
- **Data:** 09/11/2026
- **Relacionadas:** [ADR 0041](0041-continuar-a-sessao-da-etapa-anterior.md), [ADR 0039](0039-telemetria-do-runner.md), [ADR 0004](0004-execucao-de-jobs-no-runner.md)

## Contexto

Com `persist_session` e `resume_session_id` (ADR 0041), o `claude` grava a transcrição
de cada etapa na máquina do runner. Mesmo sem elas, ele deixa os resultados de
ferramentas. O diretório é do CLI, não do runner, e as sessões de todas as tarefas
ficavam no disco depois que o worktree saía.

## Decisões

1. **Onde o CLI guarda as sessões (lido no `claude` 2.1.319).**
   - A raiz é `$CLAUDE_CONFIG_DIR/projects`, ou `~/.claude/projects`.
   - O nome do diretório vem do caminho real do cwd, com symlinks resolvidos e em NFC.
     Cada unidade UTF-16 fora de `[A-Za-z0-9]` vira `-`. Acima de 200 caracteres, o
     nome fica com os 200 primeiros, um `-` e o hash do caminho em base 36.
   - Com `CLAUDE_CONFIG_DIR` definido, `CLAUDE_CODE_PROJECT_DIR_NAME` fixa um só
     diretório para todos os cwds.
   - `PipeMaestroRunner.ClaudeSessions` reproduz essa regra.
2. **O cwd de uma tarefa é o worktree dela**, `<workdir>/worktrees/<task_id>`, então as
   sessões da tarefa têm um diretório só delas.
3. **O que sai, e só isso.**
   - Sai o que está no diretório de nome exato: os `<uuid>.jsonl` e os `<uuid>/`
     (nunca um link).
   - Antes, todo `cwd` das transcrições (`<uuid>.jsonl` e `<uuid>/subagents/*.jsonl`)
     precisa ser o worktree ou estar dentro dele. Senão nada sai.
   - O diretório sai só se ficar vazio: a `memory/` do CLI, por exemplo, fica.
   - Um diretório fixo por `CLAUDE_CODE_PROJECT_DIR_NAME` é compartilhado, e nada sai dele.
4. **Quando sai.**
   - As sessões saem quando o `JobRunner` remove o worktree (`worktree:remove`: pedido
     manual, fim ou cancelamento da tarefa, retenção), depois de o worktree sair.
   - O cwd é resolvido antes da remoção.
   - Se o worktree não sai, as sessões ficam: uma etapa ainda pode retomá-las.
   - A limpeza nunca põe `error` no `worktree:removed`.
5. **Aviso quando o formato muda: `claude_sessions_not_found`.**
   - Um job com `persist_session` ou `resume_session_id` marca a tarefa
     (`<workdir>/worktrees/<task_id>.claude-sessions`).
   - Uma tarefa marcada gera o evento quando o diretório falta, não tem transcrição ou é
     compartilhado.
   - Uma transcrição de outro cwd gera o evento em qualquer tarefa.
   - Os atributos são `task_id`, `dir`, `reason` e `cli_version`.
   - O evento fica no grupo `worktree` da telemetria do runner (ADR 0039).
6. **O espaço conta.** O `bytes` do `worktree:usage` soma as sessões de cada worktree que
   existe e cai quando elas saem. O formato não muda e a versão do protocolo não sobe.

## Consequências

- O disco do runner para de acumular sessões de tarefas encerradas.
- Um segredo do workspace chamado `CLAUDE_CONFIG_DIR` muda a raiz só para o job: o
  runner procura na raiz dele, não acha e registra o evento.
- As sessões de worktrees removidos antes desta decisão ficam onde estão.
- Um control plane antigo descarta o evento desconhecido e guarda a linha como log
  comum. Um runner antigo nunca o manda.
