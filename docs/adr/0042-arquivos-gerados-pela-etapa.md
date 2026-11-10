# 0042 — Arquivos gerados pela etapa sobem como anexos

- **Status:** aceita
- **Data:** 07/11/2026
- **Relacionadas:** [ADR 0033](0033-contrato-entre-harness-e-agente.md), [ADR 0039](0039-telemetria-do-runner.md)

## Contexto

Da etapa, só o artefato Markdown (até 64 KB) chegava à plataforma. O resto do que o
agente gera no runner se perdia com o worktree ou ficava preso nele: as screenshots do
`make e2e.shots`, um CSV, um relatório. Para revisar a etapa, a pessoa precisava
desses arquivos na tarefa.

## Decisões

1. **Cada job ganha uma pasta própria, fora de qualquer worktree.**
   - O caminho é `<workdir>/files/<job_id>`, e o agente o recebe na env
     `CP_FILES_DIR`. O prompt da etapa ensina o agente a **copiar** para lá o que a
     pessoa deve ver.
   - Por ficar fora do git, a pasta não mexe na branch nem nos checks `clean` e
     `artifact_committed`.
   - O runner apaga a pasta depois do `job:finished` e ao iniciar.
2. **O envio é por HTTP, fora do canal.**
   - `PUT /api/runner/jobs/:job_id/files?path=<relativo>`, com o token do runner e o
     corpo cru (`application/octet-stream`), um arquivo por requisição.
   - Binários grandes não passam pelo WebSocket nem pela outbox em memória.
   - O `PUT` é idempotente: reenviar o mesmo caminho substitui o arquivo. O runner
     tenta de novo em erro de rede e 5xx, mas não repete um 4xx.
   - O runner sobe os arquivos de jobs que terminaram bem, que falharam e que foram
     cancelados, depois dos checks, dos gates e da entrega, e antes do
     `job:finished`. Os que não subiram são contados em `files_failed`.
3. **Os arquivos ficam no Postgres (`bytea`), na tabela `job_files`.**
   - Não há infra nova, e a cascata e o backup vêm juntos com o job.
   - O acesso passa pelo contexto `PipeMaestro.Jobs.Files`, então dá para trocar por
     object storage depois sem mexer no resto.
   - As listagens nunca carregam o conteúdo (`load_in_query: false`).
4. **Há limites, iguais nos dois lados (`PipeMaestroProtocol.JobFiles`).**
   - Até 10 MiB por arquivo, 50 MiB e 100 arquivos por job.
   - O caminho é relativo, sem `..`, `.`, `\`, NUL nem segmento vazio, e tem até
     255 bytes.
   - O runner não segue symlinks e não sobe arquivo cujo nome traz o valor de um
     segredo do job.
   - O control plane confere os totais com a linha do job travada (`FOR UPDATE`).
5. **O `content_type` vem da extensão, e só imagem raster abre no navegador.**
   - PNG, JPEG, GIF e WebP abrem `inline`. Todo o resto, SVG e HTML incluídos, vai
     como `attachment`.
   - O download sempre leva `nosniff` e `Content-Security-Policy: sandbox`, e só um
     membro do workspace o obtém.
6. **É uma capacidade, sem subir a versão do protocolo.**
   - O runner anuncia `"files"` no `Hello`, e o control plane só cita `CP_FILES_DIR`
     no prompt de quem anuncia.
   - Um control plane antigo responde 404 ao `PUT`. O runner conta os arquivos em
     `files_failed`, e o job termina como terminaria.

## Consequências

- A tarefa mostra os arquivos de cada tentativa junto do artefato, com as imagens em
  miniatura, e a aba "Anexos" junta os de todas as etapas.
- O banco cresce com o uso. A retenção (em dias) e a cota por workspace vieram depois,
  no [ADR 0054](0054-retencao-por-workspace.md). Um anexo vencido perde o conteúdo e
  guarda o nome, e um upload além da cota volta com `413 quota_exceeded`.
- O proxy na frente do control plane precisa aceitar corpos de até 10 MiB. O padrão do
  nginx é 1 MB (`client_max_body_size`). Enquanto não for ajustado, os arquivos maiores
  voltam com 413 e aparecem como "não chegaram".
