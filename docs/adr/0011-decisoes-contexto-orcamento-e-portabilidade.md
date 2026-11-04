# 0011 — Decisões registradas, contexto por pipeline, orçamento por tarefa e pipelines em YAML

- **Status:** aceita
- **Data:** 03/11/2026
- **Roadmap:** Marco 3, itens 5 a 10, de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)

## Contexto

Com gates, regras e feedback (ADR 0008), o motor já garantia o mínimo. Faltavam
cinco coisas:

- registrar as decisões humanas;
- deixar o agente propor caminhos;
- dar a um pipeline o seu próprio contexto (instruções, ferramentas de observabilidade,
  subagentes);
- limitar o custo de uma tarefa;
- levar um pipeline para fora da plataforma.

## Decisões

1. **Decisão como registro (`decisions`).** Cada decisão sobre uma tarefa pausada
   guarda:
   - a pergunta (o motivo da pausa) e as opções propostas;
   - a ação (`retry`, `advance` ou `cancel`) e a opção escolhida;
   - as instruções, quem decidiu e quando.

   O schema base de toda etapa ganha `opcoes` (opcional), para uma etapa bloqueada
   propor caminhos. A tela mostra as opções como botões, e escolher uma refaz a etapa
   com `Decisão: <opção>` no prompt. Responsável sugerido e prazo ficam para quando
   houver papéis no workspace (Marco 4).
2. **Contexto por pipeline e agente por etapa.**
   - O pipeline guarda instruções de sistema (`--append-system-prompt`), servidores
     MCP (`--mcp-config`) e agentes (`--agents`).
   - A etapa escolhe o agente que a executa (`--agent`), do repositório ou do
     pipeline.
   - A tarefa guarda esse contexto no retrato (`pipeline_context`).
   - Segredos não devem ir na configuração MCP: o formulário avisa, e a entrega
     segura de segredos fica para o Marco 4.
3. **Orçamento por tarefa.** O pipeline pode ter um teto de custo por tarefa. O teto é
   opcional e vazio por padrão: só existe quando a pessoa o configura (ADR 0028).
   - Passado o teto, a tarefa pausa para decisão em vez de seguir sozinha (para a
     próxima etapa ou para outra tentativa).
   - Quando a etapa já pausaria por outro motivo, vale esse motivo.
   - O cabeçalho da tarefa mostra o custo total e o teto.
   - A concorrência por runner já é a `capacity` (ADR 0006); um limite por workspace
     fica para o Marco 4.
4. **Mais templates:** nova funcionalidade (com aprovação do plano), refatoração,
   revisão de código, investigação de produção (só leitura) e atualização de
   dependência. As etapas que só olham dizem no prompt que não alteram código (os
   perfis de permissão saíram no [ADR 0018](0018-etapas-autonomas.md)).
5. **Pipelines em YAML.**
   - Exportar gera YAML legível, com os prompts em blocos `|` e o resto em JSON (que
     também é YAML).
   - Importar lê esse formato com `yaml_elixir` e valida como o formulário.
   - Exportar e importar dá o mesmo pipeline; o teste confere isso com todos os
     templates.
   - É o primeiro passo para um repositório sobrescrever o pipeline.
6. **Etapas em paralelo (fan-out) adiadas.** Exigem grupos de etapas no motor, dois
   agentes no mesmo worktree no runner e uma tela de pipeline em grafo. Sem um caso
   de uso que pague essa complexidade, ficam para depois.

## Consequências

- O motor passa a ter uma terceira forma de pausar, o orçamento, além das regras
  (ADR 0008) e da pausa pedida (ADR 0010).
- O protocolo ganha `system_prompt`, `mcp_config`, `agents` e `agent` no `Job`, de
  forma aditiva.
