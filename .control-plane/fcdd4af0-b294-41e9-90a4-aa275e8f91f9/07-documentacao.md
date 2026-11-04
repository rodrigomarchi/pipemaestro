# Etapa 7 — Documentação e resumo: "Últimas execuções" na página do runner

## Documentação atualizada nesta etapa

- `docs/adr/0010-conversa-com-a-tarefa.md` §7: a lista do que a página do runner mostra
  inclui as últimas execuções terminadas, cada uma levando à auditoria (ADR 0015).
- `docs/adr/0004-execucao-de-jobs-no-runner.md` §2: o runner também tira `__BURRITO` do
  ambiente do `claude`, ao lado das variáveis de sessão aninhada.
- `docs/specs/protocolo-runner.md` §4.4 (`artifact_path`): sem o campo, o runner tira
  `CP_ARTIFACT_PATH` do ambiente do agente.

Já vieram da etapa 3: o item ✓ em `docs/plano/03-roadmap-orquestrador.md` e o item
"Histórico" em `docs/guias/instalacao.md`.

**Sem ADR novo.** Não houve decisão de arquitetura: é uma consulta no domínio e um card na
LiveView. As correções no runner ajustam o ambiente do processo `claude` sem mudar o
protocolo. Por isso o índice em `docs/README.md` e o `AGENTS.md` ficam como estão, porque
nenhum contexto ou app ganhou papel novo.

## Resumo para quem revisa e faz o merge

### O que mudou

1. **Página do runner (`/w/:slug/runners/:id`):** novo card "Últimas execuções", entre
   "Jobs em execução e na fila" e "Diretórios". Ele mostra as 10 execuções mais recentes que
   o runner terminou, da mais recente para a mais antiga. Cada linha tem status, rótulo,
   duração, custo, tokens e % de cache, com "—" quando falta o dado:
   - o rótulo é o resumo do prompt numa execução avulsa;
   - numa etapa de pipeline, é "tarefa · etapa", com "(tentativa N)" quando
     `attempt > 1`.

   Cada linha leva à página do job, onde está a auditoria. A lista se atualiza ao vivo.
2. **Domínio:** `Jobs.recent_for_runner/3`
   (`apps/pipe_maestro/lib/pipe_maestro/jobs.ex`) filtra por workspace **e**
   runner, por status terminado e por `started_at` não nulo. Ordena por
   `finished_at desc, id desc` e pré-carrega `stage_run: :task`.
3. **`RunnerLive`:** o `handle_info({:job_updated, _})` só recarrega quando o job é do
   runner da página. Antes, qualquer job do workspace provocava uma recarga.
4. **Ambiente de execução (etapa 6), fora do escopo original mas necessário para o CI:**
   - `Makefile`: `unexport __BURRITO`;
   - `PipeMaestroRunner.Claude.env/2` remove `__BURRITO` e, num job sem artefato,
     `CP_ARTIFACT_PATH` do ambiente do `claude`.

   Sem isso, nenhuma etapa do pipeline que trabalhe neste repositório roda `mix test` ou
   `make e2e`: o app do runner sobe como o CLI do binário. Além disso, o artefato de uma
   etapa vazava para jobs sem artefato.
5. **e2e:** fluxo D em `e2e/tests/runner-connection.spec.ts` e locators novos em
   `e2e/pages/RunnersPage.ts`.

### Por quê

O histórico de execuções de um runner só era visível na lista geral de jobs. A página do
runner passa a responder "o que este runner fez por último e quanto custou", com um clique
até a auditoria.

### Como verificar

- `make ci` (etapa 6: exit 0, Dialyzer sem erros, cobertura acima do limite em todos os
  apps).
- `make e2e`, e `make e2e.shots FILE=tests/runner-connection.spec.ts`. Confira as capturas
  `runner-detail-no-recent-jobs` e `runner-recent-jobs` em claro e escuro.
- À mão:
  1. Abra a página de um runner online, rode um prompt em `/w/:slug/jobs` e volte à página
     do runner (ou deixe-a aberta).
  2. A linha aparece com custo e cache.
  3. O link abre a execução com a auditoria.

### Riscos e decisões a conferir

- **Interpretação de "terminou":** um job cancelado ainda na fila não entra, porque nunca
  rodou no runner. Um job que o `reconcile` deu como falho entra. Para incluir os cancelados
  na fila, basta tirar o filtro `started_at`.
- **Desempenho:** a consulta usa o índice `jobs(runner_id, status)` e ordena por
  `finished_at` com `limit 10`. Se o volume por runner crescer muito, um índice
  `jobs(runner_id, finished_at)` resolve.
- **Empate em `finished_at`** (resolução de segundo): o desempate por `id` é estável mas não
  cronológico.
- **Mudança no runner:** é pequena e coberta por teste, mas exige uma nova versão do
  binário para chegar aos runners instalados. Até lá, `make` dentro de jobs continua
  protegido pelo `unexport` do `Makefile`.
- **Pendências menores da revisão (etapa 4), não aplicadas:**
  - o card de jobs ativos ainda rotula etapas pelo prompt, e o card novo por
    "tarefa · etapa";
  - a regra "tokens sem dado" está duplicada entre `RunnerLive` e `TaskLive.Show`;
  - faltam testes para "(tentativa N)" e para a reserva `wall_ms`.

  Cabem num ajuste posterior.
