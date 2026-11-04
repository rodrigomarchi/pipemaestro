# 0013 — Distribuição e entrega no git e no GitHub

- **Status:** aceita
- **Data:** 03/11/2026
- **Roadmap:** Marcos 5 e 6 de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)

## Contexto

O runner só rodava via `mix runner.*` dentro deste repositório, e o control plane não
tinha como ser implantado. Por decisão do roadmap, a integração com git e GitHub ficou
por último: até aqui, commit, push e PR eram a critério do prompt de cada etapa.

## Decisões

### Distribuição (Marco 5)

1. **Os comandos do runner saem do Mix.**
   - `ClaudeControlPlaneRunner.Commands.*` têm a lógica e escrevem por `Output` (o
     shell do Mix ou o terminal).
   - As tasks `mix runner.*` viram atalhos.
   - A release ganha um lançador, `cp-runner <comando>`, que chama
     `ClaudeControlPlaneRunner.Main` com `eval`.
   - `make runner.install` instala a release em `~/.local/share` e o lançador em
     `~/.local/bin`. (A release Mix é gerada por `make runner.rel`; o
     `make runner.release` cria uma versão, como no [ADR 0016](0016-esquema-de-versao.md).)
   - O `cp-runner service install` instala o serviço apontando para o próprio
     lançador.
2. **Burrito fica para depois.** O binário único precisa de Zig no build. A release
   (com seu tarball) já roda sem Elixir na máquina de destino, desde que o sistema seja
   igual ao do build. (Feito depois: [ADR 0014](0014-pendencias-do-roadmap.md).)
3. **Imagem do control plane** (`Dockerfile`, `make image`).
   - Constrói e roda sobre `elixir:1.20.4-otp-28-slim`, para a ERTS da release casar
     com as bibliotecas do sistema.
   - `bin/server` aplica as migrations e sobe o servidor.
   - Validada de ponta a ponta: num banco vazio, migra e responde em `/healthz`.
   - As variáveis, o proxy com WebSocket e o primeiro operador estão em
     [`guias/instalacao.md`](../guias/instalacao.md).
4. **Sinal ao grupo de processos com fallback.** Logo depois do spawn, o grupo do
   processo pode ainda não existir. Um `kill -- -PID` então não acha ninguém, e o
   cancelamento se perdia: era a falha intermitente dos testes. Nesse caso, o sinal vai
   ao próprio processo (`Shell.signal/2`).

### Git e GitHub (Marco 6)

5. **Entrega determinística no runner.** O pipeline escolhe a `delivery`:
   - `none`: os prompts decidem;
   - `commit`: um commit por etapa;
   - `pr`: commit, push do branch da tarefa e PR em rascunho, aberto na primeira etapa,
     atualizado a cada uma e marcado como pronto na última.

   O runner entrega depois do agente e dos gates, e só quando a etapa terminou bem
   (saída `ok`) com todos os gates atendidos.
   - O commit deixa de fora o que o setup clonou e não acontece se nada mudou.
   - Commit e push usam `git`; PR e comentário usam o `gh` de quem roda o runner.
   - Uma falha vira `error` na entrega, sem derrubar a etapa.
   - A mensagem de commit e o corpo do PR (o pedido, `Closes <issue>` e a lista de
     etapas) são montados pelo control plane, não pelo agente.
6. **Issue como origem, pela URL.**
   - A tarefa aceita o link de uma issue do GitHub.
   - O PR a fecha (`Closes`).
   - Cada decisão vira um comentário na issue, entregue com a etapa seguinte.
   - A página **Pull requests** lista as tarefas com PR.
7. **Fora deste passo:**
   - **Webhook por label**, para criar a tarefa sozinha: exige que o control plane
     receba eventos do GitHub.
   - **GitHub App com token por tarefa**, para runners de clientes, sem o `gh` de uma
     pessoa.

   Os dois ficam para quando o produto sair da máquina do dev.

## Consequências

- O protocolo ganha `delivery` no `Job` e no `job:finished`, de forma aditiva.
- Com `delivery: pr`, o runner precisa de `origin` e de um `gh` autenticado; o
  `cp-runner doctor` mostra o git, mas ainda não o `gh`.
