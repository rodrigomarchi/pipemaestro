# 0048 — O drawer de um nó em abas: o que importa primeiro

- **Status:** aceita
- **Data:** 08/11/2026
- **Relacionadas:** [ADR 0047](0047-um-desenho-de-pipeline.md)

## Contexto

O drawer de um nó ([ADR 0047](0047-um-desenho-de-pipeline.md)) mostrava todos os campos
de uma vez. Numa etapa, o prompt dividia a tela com tentativas, teto, tempo, gates,
regras e um bloco recolhido de avançados; na entrada, nome, entrega, merge,
instruções, servidores MCP e agentes. O que se edita quase sempre, o prompt e o
modelo, se perdia no meio do resto.

## Decisões

1. **Todo drawer de nó abre em abas, e a primeira é o que importa.**
   - `PipelineComponents.drawer_tabs/1` é a barra, igual em todo drawer. Ela fica
     presa ao topo enquanto o conteúdo rola, e um clique manda `select_tab`.
   - **Etapa, no editor:** **Prompt** (nome, modelo e o prompt, maior),
     **Execução** (tentativas, teto e tempo), **Verificação** (gates e regras) e
     **Avançado** (chave, contexto, agente, grupo e saída estruturada).
   - **Entrada, no editor:** **Geral** (nome, descrição e instruções de sistema),
     **Entrega** (teto, entrega e merge) e **Avançado** (servidores MCP e agentes).
   - **Leitura** (a página do pipeline, a proposta, o Uso e a etapa que ainda não
     rodou na tarefa): os mesmos nomes. Uma aba só aparece quando tem conteúdo, e
     sem uma segunda aba a barra não é desenhada.
2. **Abrir um nó volta à primeira aba.** O editor (`PipelineLive.Form`), o
   `PipelineExplorer` e o painel da etapa na tarefa guardam a aba como estado da
   tela, não da URL.
3. **Um erro não fica escondido.**
   - A aba escondida continua na página e envia os seus inputs.
   - Uma aba com um campo em erro ganha um ponto vermelho.
   - Ao salvar com erro, abre o drawer que o mostra, na aba onde ele está. Se a aba
     aberta já mostra um erro, ela continua aberta.

## Consequências

- O drawer de uma etapa é o prompt, com o modelo ao lado; o resto fica a um clique.
- Ver todos os campos de um nó de uma vez pede passar pelas abas.
