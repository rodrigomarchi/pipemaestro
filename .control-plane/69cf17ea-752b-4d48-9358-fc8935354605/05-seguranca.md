# Revisão de segurança — Linha do tempo compacta com ícones dos eventos

Escopo: `git diff main...HEAD` (componentes de job, `JobLive`, `TaskLive.Show`,
`config/test.exs`, `config/e2e.exs`, `config/worktree.exs`, `Makefile`, o
`fake_claude` de teste e os specs e2e).

**Veredito: sem riscos graves nem médios.** A mudança é de apresentação; não
toca autorização, contextos de domínio, canal do runner nem segredos.

## Autorização e isolamento entre workspaces

- `JobLive.mount/3` continua carregando o job por `Jobs.get_job!(workspace, id)`,
  com o escopo do workspace; a assinatura `{:job, job.id}` vem depois disso,
  então ninguém recebe eventos de job de outro workspace.
- Em `TaskLive.Show.handle_info({:job_event, …})` o filtro
  `event.job_id == live_job_id` continua valendo (`with`). Eventos de outro job
  são descartados como antes.
- Papéis admin e membro: nenhuma ação nova. Abrir e fechar os painéis é só
  `Phoenix.LiveView.JS` no cliente, sem `handle_event` novo no servidor.

## Dados vindos do runner (canal) e injeção

- O que vem de `Event.data` (nome da ferramenta, `command`, `description`,
  `file_path`, `pattern`, texto, `status`, `source`) agora também aparece no
  tooltip (`tooltip={@summary}`) e no `aria-label` do `icon_button`. Os dois
  passam por atributos/interpolações HEEx, que fazem escape; não há `raw/1` nem
  `Phoenix.HTML.raw` novos. Sem XSS.
- O novo `event_look/1` de fallback mostra `type` como rótulo. `type` é
  validado no domínio (`validate_inclusion(:type, JobEvent.types())` em
  `Jobs.Event`) e passa por escape de qualquer forma.
- Os seletores CSS montados em `toggle_panel/3` usam só ids gerados pelo
  servidor (o id fixo da timeline, o id DOM do stream e `event.id`, que é chave
  do banco), nunca dados enviados pelo runner. Sem injeção de seletor.
- `timeline_push/2` deduplica por `seq` num `MapSet` por página. O tamanho é
  limitado pelo número de eventos do job, que já é o que a página carrega. Não
  cria vetor novo de exaustão de memória.
- Robustez (não é risco novo): `utilization_labels/1` (`round(used * 100)`) e
  `short_number/1` quebram se o runner mandar algo que não seja número. Isso já
  acontecia no corpo dos eventos `rate_limit`/`compact`, e o efeito fica restrito
  ao processo LiveView de quem está olhando. Agora a mesma conta roda também no
  tooltip, mas só para esses mesmos tipos de evento.

## Segredos e dados sensíveis na tela

- A tela não mostra nenhum campo novo: o tooltip resume o que o painel do
  evento já exibia (comando, caminho, padrão, tamanho da saída, tokens). Os
  segredos entregues ao runner por job não passam pelos eventos renderizados.
  A mudança não altera o que se grava nem o que se mostra.
- Nenhum log novo.

## Configuração e Makefile

- `config/worktree.exs` lê `.git` do próprio checkout e normaliza o nome
  (`[^a-z0-9]` removido, até 8 caracteres) antes de usar no nome do banco. Não
  dá para injetar nada no nome do banco. Só é avaliado em `test` e `e2e`, não em
  `prod`/`runtime.exs`.
- No `Makefile`, `WORKTREE` passa por `tr -dc 'a-z0-9'` antes de ir para a
  expansão aritmética do shell. Sem injeção de comando por nome de worktree.
- `fake_claude` (`[gotejando]`) é só suporte de teste, sem impacto em produção.

## Recomendações (não bloqueiam)

- Opcional: validar no domínio que `utilization`/`pre_tokens` sejam numéricos,
  ou fazer a formatação tolerante a valores que não sejam número, para que um
  runner com defeito não derrube a página do job. A falha já existia antes desta
  mudança.
