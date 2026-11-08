# 0047 — Um desenho só de pipeline: vertical, editado num drawer

- **Status:** aceita
- **Data:** 08/11/2026
- **Relacionadas:** [ADR 0040](0040-diagrama-do-pipeline.md), [ADR 0046](0046-pagina-da-tarefa-em-fases.md)

## Contexto

O pipeline tinha dois desenhos. A tarefa mostrava as etapas num trilho vertical, e
cada etapa abria num drawer largo com fundo escurecido
([ADR 0046](0046-pagina-da-tarefa-em-fases.md)). A página do pipeline, o editor, a
proposta e o Uso mostravam o diagrama horizontal da [ADR 0040](0040-diagrama-do-pipeline.md),
com um painel estreito. O editor ainda tinha uma segunda aba, Formulário, com um
cartão por etapa.

O horizontal rolava de lado no celular, e a mesma coisa tinha duas aparências.

## Decisões

1. **Todo pipeline é desenhado de cima para baixo, no mesmo trilho.**
   - `PipelineComponents.rail_item/1` é o lugar de um passo no trilho: o marcador
     na linha e o conteúdo ao lado. A tarefa (`TaskLive.PipelineView`) e
     `pipeline_diagram/1` o usam.
   - Os nós continuam ricos: chips, tentativas, entrega, regras e, nas camadas, o
     estado, as medidas e a comparação. Um passo em paralelo põe as etapas lado a
     lado.
   - A falha que para a tarefa (esgotou ou bloqueou) fica no rodapé do nó; as regras
     de "pedir ajuda", numa faixa tracejada do nó. O trilho "Pessoa decide" fecha o
     diagrama, com o teto de custo.
   - Só a miniatura (`:compact`) e os pontos (`:micro`) seguem em linha.
2. **O editor é só o diagrama.**
   - Sai a aba Formulário (`?view=form`) e o cartão por etapa.
   - Um `+` na linha insere uma etapa entre dois passos, e "Adicionar etapa" a põe
     depois da última; o nó sobe, desce, remove e entra ou sai de um grupo.
   - A entrada abre os campos do pipeline; uma etapa, os seus.
3. **Um drawer só.**
   - `side_panel/1` é sempre o drawer da tarefa: 90% da tela larga, a tela toda no
     celular, sobre um fundo que fecha ao clicar.
   - Continua na página quando fechado, para os inputs seguirem no form.
   - Um erro ao salvar abre o drawer que o mostra, se o aberto não o mostra.

## Consequências

- Nada rola de lado: o diagrama cabe no celular.
- Um pipeline longo fica mais alto, não mais largo.
- Revisar todos os campos de uma vez deixou de existir; cada etapa é revista no seu
  drawer.
- Substitui as decisões 2 e 4 da ADR 0040 e a consequência de rolar na horizontal.
