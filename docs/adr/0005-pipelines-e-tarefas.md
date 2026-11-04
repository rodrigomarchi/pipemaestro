# 0005 — Pipelines no control plane e tarefas no runner

- **Status:** aceita
- **Data:** 04/11/2026
- **Muda:** a decisão "Definição do pipeline" do §2 da [visão](../plano/01-visao-arquitetura.md)
  ("totalmente definido pelo projeto, versionado no repo do cliente").

## Contexto

Com o runner executando prompts avulsos (ADR 0004), o próximo passo da Fase 0 é o
coração do produto: uma tarefa que percorre etapas em ordem determinística, cada uma
com contexto novo, comunicando-se por artefatos, com gates mecânicos e pausas para
decisão humana. Ainda sem GitHub e sem containers: o runner roda na máquina do dev,
com o toolchain dela.

## Decisões

1. **O pipeline é persistido no control plane**, por workspace, e é genérico: o mesmo
   pipeline serve a qualquer projeto. Isso permite editar pela plataforma e reutilizar
   sem instalar arquivos em cada repositório. O específico de cada projeto vem do
   próprio repo (`CLAUDE.md`, `AGENTS.md`, `.claude/`), que o `claude` já lê. O formato
   é dado estruturado, o que deixa aberta uma futura importação ou exportação, ou um
   repo que sobrescreva o pipeline.
2. **Versão e retrato.** Cada salvamento sobe a `version`. A tarefa grava, ao começar,
   o retrato do pipeline (nome, versão e etapas): editar o pipeline nunca muda uma
   tarefa em andamento, e a auditoria sabe com quais prompts cada etapa rodou.
3. **Diretórios do runner.** O runner sobe com uma raiz (`--root ~/src`) e anuncia
   todos os subdiretórios do primeiro nível, marcando os que são git. A tarefa escolhe
   o runner, o diretório, o pipeline e o prompt. A tarefa fica presa ao runner escolhido
   e ainda não há dispatcher.
4. **Worktree por tarefa.** Num diretório git, o runner cria um `git worktree`
   (`<workdir>/worktrees/<tarefa>`, branch `cp/<título>-<id>`) a partir do `HEAD` do
   checkout. Todas as etapas da tarefa rodam nele, e o checkout do dev não é tocado.
   Dependências e build não existem no worktree, então a primeira etapa paga esse
   custo; as seguintes o reaproveitam. O runner confere que o diretório é a raiz do
   próprio repositório, porque o git subiria até um repositório que o contenha. Num
   diretório sem git, a tarefa roda direto na pasta.
5. **Commit, push e PR ficam a critério do prompt.** O runner só cria o worktree. A
   integração com o GitHub entra no passo seguinte.
6. **Contrato de toda etapa:**
   - responder com saída estruturada (`--json-schema`) com pelo menos `status`
     (`ok` ou `bloqueado`) e `resumo`, mais os campos extras do schema da etapa;
   - escrever um artefato Markdown em `.control-plane/<tarefa>/<NN>-<chave>.md`;
   - ler os artefatos das etapas anteriores, listados no prompt.

   O prompt da etapa é um template com variáveis (`{{tarefa.descricao}}` e outras)
   precedido de um cabeçalho fixo com essas regras.
7. **Gate** (`ClaudeControlPlane.Tasks.Engine`, puro):
   - **Aprovada:** saída `ok` com artefato. A tarefa segue para a próxima etapa, sem
     aprovação humana ([ADR 0018](0018-etapas-autonomas.md)).
   - **Bloqueada:** saída `bloqueado`. Pausa sem retentativa, porque o agente pediu uma
     pessoa.
   - **Erro:** CLI falhou, sem saída estruturada ou sem artefato. Gera nova tentativa
     até o limite da etapa, e depois pausa.
8. **Decisões por prompt.** Uma tarefa em "aguardando decisão" continua com
   instruções da pessoa: **refazer a etapa** ou **seguir para a próxima**, com as
   instruções acrescentadas ao prompt. A pessoa também pode cancelar. Cada tentativa
   fica registrada com as instruções que recebeu.
9. **O protocolo passa à v3:** diretórios no `Hello` e em `runner:directories`, e
   contexto da etapa no `job:assign` (diretório, worktree, schema, modelo, orçamento,
   caminho do artefato). O `job:finished` passa a trazer a saída estruturada, o
   artefato e o diretório real.

## Fora deste passo

- GitHub: issue como origem, push e PR automáticos.
- Board com tarefas reais.
- Gate por comando de teste do projeto.
- Dispatcher e afinidade.
- Limpeza de worktrees antigos.
- Importação e exportação de pipelines.
