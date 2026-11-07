# 0040 — O diagrama é a visão padrão do pipeline

- **Status:** aceita
- **Data:** 07/11/2026
- **Relacionadas:** [ADR 0001](0001-biblioteca-de-componentes.md), [ADR 0005](0005-pipelines-e-tarefas.md), [ADR 0018](0018-etapas-autonomas.md)

## Contexto

Um pipeline só aparecia como formulário: uma lista de cartões, um por etapa, e só para
admins. O fluxo que a tarefa percorre ficava implícito nos campos:

- os passos em paralelo (etapas seguidas com o mesmo `group`);
- as tentativas e os gates de cada etapa;
- as regras e falhas que param a tarefa para uma pessoa;
- o teto de custo e a entrega.

Um membro não tinha como ver um pipeline em detalhe.

## Decisões

1. **O pipeline tem página própria, `/pipelines/:id`, para todo membro.**
   - A página mostra o pipeline como diagrama de nós conectados: entrada, passos,
     entrega e fim.
   - Embaixo fica o trilho "Pessoa decide", para onde vão as arestas de cada etapa
     (esgotou ou bloqueou, cada regra) e o teto de custo.
   - Um nó abre os detalhes da etapa num painel lateral.
   - A lista leva à página, e o editor volta para ela ao salvar.
2. **O editor abre no diagrama.**
   - `/edit` e `/new` têm duas abas: Diagrama (padrão) e Formulário (`?view=form`).
   - No Diagrama, um nó abre os campos da etapa num painel.
   - O `+` entre os passos insere uma etapa; cada nó move, remove e entra ou sai de um
     grupo em paralelo.
3. **Um modelo puro, componentes compartilhados.**
   - `PipeMaestroWeb.PipelineDiagram` transforma um `Pipeline` no que se desenha. O
     pipeline pode ser o salvo ou o rascunho do form, via
     `Ecto.Changeset.apply_changes/1`.
   - `PipeMaestroWeb.PipelineComponents` desenha o diagrama nos modos `:read`, `:edit`
     e `:compact` (a miniatura da lista), além dos detalhes, dos chips e do painel.
   - A regra de quais etapas formam um passo é uma só, `PipeMaestro.Pipelines.steps/1`.
     A usam o motor da tarefa e o diagrama.
4. **Cada campo é renderizado uma vez.**
   - As duas abas são o mesmo `<.form>`. Cada campo
     (`PipeMaestroWeb.PipelineLive.FormFields`) aparece uma vez, dentro da moldura da
     aba: um cartão no Formulário, um painel no Diagrama.
   - O painel fechado continua na página, oculto, e seus inputs seguem no form. Por
     isso o painel é próprio (`side_panel/1`, com as classes do Petal): o `slide_over`
     do Petal só abre ao ser montado.
5. **A estrutura continua válida enquanto se edita.**
   - `PipeMaestroWeb.PipelineLive.StageParams` move, insere, remove e agrupa sobre os
     params do form.
   - Depois de cada mudança, a primeira etapa, que prepara o worktree, sai de qualquer
     grupo, e um grupo que ficou com uma etapa só deixa de ser grupo.
   - Por isso "paralelizar com a anterior" só existe a partir da terceira etapa.

## Consequências

- O desenho é HEEx com CSS grid e SVG inline, sem biblioteca de grafos nem JS. O
  layout segue a forma do pipeline, uma sequência de passos, cada passo com uma ou
  mais etapas.
- Um pipeline longo rola na horizontal, inclusive no celular.
- O caminho de falha está desenhado em toda etapa, o que é fiel à máquina de estados
  ([`maquina-de-estados-tarefa.md`](../specs/maquina-de-estados-tarefa.md)) às custas
  de um diagrama mais carregado.
