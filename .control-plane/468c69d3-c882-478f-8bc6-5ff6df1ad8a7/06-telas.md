# 06 — Telas (e2e)

A tarefa mudou uma tela: a página da tarefa (`/w/:slug/tasks/:id`), aba Etapas, com o pipeline vertical e o painel da etapa.

## Execução

- `make e2e > /tmp/e2e.log 2>&1; echo $?` → **0**, 37 specs passaram (duas vezes: antes e depois do ajuste visual).
- `make e2e.shots FILE=tests/task-stage-panel.spec.ts` → 2 passaram; as imagens, claro e `-dark`, estão em `$CP_FILES_DIR/telas/task-stage-panel/`. Não vão para o git (`e2e/screenshots` é ignorado).
- `make ci.quick` depois do ajuste → **0** (com 256 descritores).

## Telas e estados conferidos (claro e escuro)

| Tela / estado | Imagem | Resultado |
|---|---|---|
| Visão geral, etapa rodando | `02-task-overview` | Pipeline vertical (Entrada → Executar → Fim), nó em execução destacado em azul, coluna lateral com a mensagem, pausa e interrupção. Contraste e alinhamento bons nos dois modos. |
| Painel ao vivo | `03-task-stage-panel-live` | Painel com ~90% da largura, fundo escurecido, timeline ao vivo com os ícones, "até agora US$ … · N tokens". |
| Painel concluído | `04-task-stage-panel-finished` | Artefato primeiro, "Ver texto", detalhes dobrados, "Refazer a partir daqui". |
| Aviso de decisão | `02-task-decision-banner` | Aviso com a razão e "Decidir" sobre o pipeline; nó em warning com duração e custo. |
| Painel com decisão | `03-task-stage-panel-decision` | Razão, diagnóstico, questionário, "Decidir sem responder" no topo; a tentativa bloqueada abaixo. |
| Celular: painel | `05-task-stage-panel-phone` | Painel em 100% da largura, sem rolagem lateral. |
| Celular: visão geral | `06-task-overview-phone` | Uma coluna: pipeline e, abaixo, "Corrigir com um prompt". |

O fundo escuro do aviso de decisão (alerta amarelo claro) é o do alerta `warning` do Petal, igual ao da razão da decisão no painel, e não foi alterado.

## O que ajustei

No cabeçalho da tentativa (`TaskLive.AttemptComponents.attempt/1`):

- No celular, a duração e o custo quebravam em duas linhas ("1 / s", "US$ / 0.0042"). As métricas agora ficam em `whitespace-nowrap` e o grupo quebra por item (`flex-wrap`), com o link de auditoria descendo para a linha de baixo.
- Com a tentativa rodando, o cabeçalho mostrava dois "—" (duração e custo ainda sem valor). Agora cada um só aparece quando existe.

## Pendência de leitura

O painel concluído na tela larga tem muito espaço vazio abaixo do artefato; é o comportamento esperado (o conteúdo rola por dentro quando cresce) e nada foi mudado.
