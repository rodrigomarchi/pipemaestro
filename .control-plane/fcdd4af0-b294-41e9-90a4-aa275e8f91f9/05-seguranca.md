# Revisão de segurança — Últimas execuções na página do runner

Escopo: `git diff main...HEAD` (`Jobs.recent_for_runner/3`, `RunnerLive`, testes, e2e e docs).

**Veredito: sem riscos graves nem médios.**

## Autorização (admin e membro)

- A seção é só leitura e não acrescenta nenhum `handle_event`. A única ação da página
  (`revoke`) continua protegida por `can?(scope, :manage_runners)`.
- Membros já veem todos os jobs do workspace (`Jobs.list_jobs/1` e `Jobs.get_job!/2` são
  escopados por workspace, não por autor), e a página do runner já listava os jobs ativos de
  qualquer autor. Mostrar os jobs terminados a um membro não amplia o que esse papel já acessa.
- O link leva a `/w/:slug/jobs/:id`, que recarrega o job por `get_job!(workspace, id)`.
  Montar a URL não concede acesso por si só.

## Isolamento entre workspaces

- `recent_for_runner/3` filtra por `workspace_id` **e** `runner_id`. O runner vem de
  `Runners.get_runner!(workspace, id)`, que já é escopado pelo workspace do `current_scope`.
  O filtro extra por workspace é uma defesa em profundidade, e o teste "only this workspace's
  jobs on this runner" cobre o caso de um workspace alheio.
- O preload `stage_run: :task` segue as FKs do próprio job. Não há como trazer a tarefa de
  outro workspace.
- A assinatura PubSub continua sendo o tópico `{:workspace, id}` do workspace do usuário. O
  novo `handle_info` só filtra por `runner_id`, o que reduz recargas e não abre tópico novo.

## Canal do runner, formulários e injeção

- Nenhuma mudança no protocolo, no canal nem em formulários.
- A consulta é Ecto com parâmetros fixados (`^workspace_id`, `^runner_id`, `^limit`), sem
  SQL cru. `limit` não vem do usuário (o padrão é 10).
- O texto exibido (título da tarefa, nome da etapa, resumo do prompt) é renderizado por
  HEEx com escape automático. Não há `raw/1`. Os ids nos atributos são UUIDs.

## Segredos e dados sensíveis

- Nenhum log foi acrescentado. A tela mostra status, duração, custo, tokens, cache e um
  resumo truncado do prompt (70 caracteres), dados que a página do job já exibe aos mesmos
  usuários. Não exibe segredos, tokens do runner nem env.

## Observações (sem ação necessária)

- `handle_info({:job_updated, %Job{}})` só casa com `%Job{}`. Os broadcasts em `jobs.ex`
  sempre enviam a struct, então nenhuma mensagem dependente é engolida ou derruba o processo.
