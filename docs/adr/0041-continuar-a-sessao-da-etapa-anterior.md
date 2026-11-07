# 0041 — Uma etapa pode continuar a sessão do agente da etapa anterior

- **Status:** aceita
- **Data:** 07/11/2026
- **Relacionadas:** [ADR 0004](0004-execucao-de-jobs-no-runner.md), [ADR 0005](0005-pipelines-e-tarefas.md), [ADR 0021](0021-propostas-de-pipeline-pelo-agente.md)

## Contexto

Cada etapa de uma tarefa rodava o `claude` com contexto zerado
(`--no-session-persistence`, ADR 0004). A etapa seguinte só sabia o que a anterior
deixou nos artefatos e no worktree. Em etapas que se emendam (planejar e depois
implementar, implementar e depois corrigir), o agente perdia o que tinha lido e
decidido e precisava reconstruir tudo.

## Decisões

1. **A etapa escolhe como começa: `context`, `"fresh"` (padrão) ou `"continue"`.**
   - `PipeMaestro.Pipelines.Stage.context`, campo do embed. Pipelines, tarefas e
     YAMLs antigos carregam `"fresh"`; o YAML só escreve `context` quando é `"continue"`.
   - No formulário, o seletor "Contexto" fica no bloco "Avançado" da etapa.
2. **Só a etapa imediatamente anterior, e só fora de grupos.**
   - O pipeline recusa `"continue"` na primeira etapa, numa etapa com `group` e numa
     etapa cuja anterior tem `group`. O erro fica no campo `context` da etapa.
   - Um grupo roda várias sessões ao mesmo tempo: não há uma sessão só para continuar.
3. **O control plane pede, o runner executa.**
   - O job de uma etapa seguida por uma que a continua leva `persist_session: true`:
     o CLI guarda a sessão, e o `session_id` volta no `job:finished`.
   - O job de uma etapa `"continue"` leva `resume_session_id`: o `session_id` da última
     tentativa **aprovada** da etapa anterior. Uma nova tentativa retoma a mesma
     sessão; o retorno da falha segue no prompt, como antes.
   - O runner roda `claude --resume <id> --fork-session`. O fork deixa a sessão da
     etapa anterior intacta para outras tentativas, e cada job tem seu `session_id`.
4. **Sem a sessão, a etapa começa do zero, sem travar.**
   - O CLI que não acha a sessão termina com erro antes da linha `system`. O runner
     então roda o job de novo, uma vez, sem `--resume`, no mesmo lugar, sem refazer o
     setup, e responde `session_resumed: false`.
   - Isso cobre uma tarefa que trocou de runner e um worktree recriado noutra máquina.
   - A tela da tarefa mostra, na tentativa, "Continuou a etapa anterior" ou "Começou do
     zero: a sessão anterior não estava disponível"; a auditoria do job mostra a
     sessão retomada.
5. **Capacidade `"resume_session"`, sem subir a versão do protocolo.**
   - Os campos são opcionais e aditivos. O control plane só os põe no job de um
     runner que anunciou a capacidade; um runner antigo roda toda etapa do zero.

## Consequências

- A sessão continuada carrega todo o histórico da anterior: mais contexto e mais
  cache por etapa. Compactar a sessão fica para depois.
- Com `persist_session`, o CLI grava a transcrição em `~/.claude/projects/` na máquina
  do runner, o que antes não acontecia. Apagar essas sessões quando o worktree da
  tarefa sai fica pendente: o diretório é do CLI, não do runner.
- A detecção da sessão ausente depende de o CLI falhar antes da linha `system`. Se
  uma versão do CLI emitir a linha antes de falhar, a tentativa falha normalmente e
  a próxima segue o fluxo de tentativas, sem travar a tarefa.
- A etapa de correção que a tarefa insere continua começando do zero.
