# 0046 — Verificação uma vez por árvore

- **Status:** aceita
- **Data:** 08/11/2026
- **Relacionadas:** [ADR 0008](0008-projetos-gates-e-feedback.md), [ADR 0033](0033-contrato-entre-harness-e-agente.md), [ADR 0043](0043-runner-resiliente-a-reinicios.md)

## Contexto

Uma auditoria das dez últimas tarefas do pipeline "Evolução do PipeMaestro" (de 04/11 a
08/11/2026) mediu, nos `job_events` e nos `gates` dos jobs, quanto tempo foi gasto
verificando. Mais da metade do tempo das etapas foi suíte rodando, e a maior parte dele
nos turnos do agente, não nos gates:

| | minutos |
|---|---|
| Tempo das etapas | 624 |
| Verificação rodada pelo agente nos turnos | 272 |
| Verificação rodada pelos gates | 67 |

Na maior parte, o tempo foi repetição:

- **A mesma árvore passava pela suíte várias vezes seguidas**, sem código novo entre uma
  vez e outra:
  - o fim da Implementação (`ci.quick`) e o gate dela (`mix test --cover`);
  - a Revisão (`ci.quick`) e o gate dela;
  - a etapa de CI (`make ci`) e o gate dela (`make ci`);
  - depois, Telas, Documentação e Entrega rodavam tudo de novo.
- **O e2e completo era o maior custo:**
  - o agente o rodava na Implementação, em Telas, na Documentação e na Entrega;
  - o gate de Telas o rodava mais uma vez;
  - em vinte das vezes, a execução anterior tinha passado e nenhum arquivo de código
    tinha mudado desde então.
- **A Implementação rodava a suíte do umbrella inteiro a cada ajuste**, em vez dos testes
  que a mudança toca.
- **Tarefas paralelas se atrapalhavam:**
  - o Forgejo e o GitHub falsos do e2e tinham portas fixas e caíam com `EADDRINUSE`;
  - os logs em `/tmp/ci.log` e `/tmp/e2e.log` eram os mesmos para todos os worktrees.

O agente não sabia quais gates viriam depois dele, e os prompts, o `AGENTS.md` e as notas
do projeto mandavam rodar `make ci` em toda etapa.

## Decisão

**Uma árvore é verificada uma vez por comando; cada etapa verifica o que tocou; os gates
fazem a prova final.**

- **O runner não roda de novo um gate que já passou na mesma árvore**
  (`PipeMaestroRunner.GateCache`):
  - a chave é a árvore do diretório de trabalho:
    - entram as mudanças e os arquivos novos;
    - ficam de fora os ignorados, a pasta de artefatos da tarefa e o que o setup copiou;
    - entram também o comando e a expectativa do gate;
  - o resultado vem com `"cached": true`, `duration_ms` 0 e um `output` que diz quando
    passou;
  - só gates que passaram entram no cache;
  - comandos que leem o remoto (`fetch`, `pull`, `ls-remote`, `origin`) nunca entram,
    porque a resposta deles muda com o origin;
  - o cache fica no git dir do worktree. Some com ele e sobrevive a um reinício do runner;
  - um diretório fora do git, ou que o repositório ignora, não tem cache.
- **O prompt de cada etapa lista os gates dela** (`PipeMaestro.Pipelines.Prompt`, seção
  "Gates desta etapa"):
  - os comandos já vêm com as variáveis do projeto preenchidas;
  - o prompt diz que não é preciso rodá-los só para ver o resultado. É um fato do
    contrato, não uma proibição (ADR 0033).
- **Neste repositório, `make ci`, `make ci.quick`, `make test.cover` e `make e2e` rodam
  uma vez por árvore** (`scripts/verified.sh`):
  - a mesma chave vale para o agente e para os gates do projeto;
  - um `ci.quick` que passa vale também para `test.cover`;
  - o `ci` reaproveita o `ci.quick`;
  - `FORCE=1` roda de novo.
- **Política de verificação** (`AGENTS.md`, "Verify what the change touches, once"):
  - teste escopado enquanto itera;
  - a suíte inteira no máximo uma vez, no fim;
  - e2e de uma spec enquanto mexe na tela;
  - mudanças só de documentação não pedem suíte;
  - logs em `tmp/`.
- **O e2e de cada worktree tem as próprias portas para os hosts git falsos**
  (`E2E_PORT` + 1000 e + 2000).

## Consequências

- Um gate que repete a etapa anterior sem mudança de código custa o tempo de um
  `git write-tree`.
- Um teste instável que passou uma vez não roda de novo naquela árvore.
  - Isso vale também para o resultado em cache: ele não é uma segunda opinião.
  - Quem quiser outra execução muda a árvore ou usa `FORCE=1`, no Makefile.
- Um gate que depende de algo fora da árvore e fora do remoto pode reaproveitar um
  resultado velho. Exemplos: um serviço externo, a hora, uma variável do ambiente.
  - Os gates de hoje (suíte, lint, e2e, estado do git) dependem da árvore.
  - Um gate desse tipo, se aparecer, precisa mudar algo na árvore ou ler o remoto.
- A pasta de artefatos fica fora da chave. Um gate que conferisse o conteúdo dos
  artefatos seria reaproveitado depois de um artefato novo. Nenhum gate faz isso; essa
  conferência é das verificações da plataforma (ADR 0033).
