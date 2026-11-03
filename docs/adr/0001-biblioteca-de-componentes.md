# 0001 — Biblioteca de componentes de UI: petal_components

- **Status:** aceita
- **Data:** 03/11/2026

## Contexto

O produto é um painel operacional em tempo real: board por etapa do pipeline, linha do
tempo da tarefa, stream de eventos, decisões humanas, executores, uso e limites. O
objetivo é ter componentes visuais ricos e bonitos que encurtem o desenvolvimento, sem
comprometer o gate do projeto (compile sem warnings, `credo --strict`, Dialyzer,
cobertura de 60%).

O `phx.new` entrega daisyUI 5 e um `core_components.ex` gerado com um conjunto mínimo de
componentes.

## Opções avaliadas (dados de 03/11/2026)

| | petal_components | Fluxon UI | SaladUI | Mishka Chelekom |
|---|---|---|---|---|
| Componentes | 64 gratuitos | ~30 | ~32 | ~73 estilizados + headless |
| Data table, gráficos, timeline, stepper, sidebar | sim | não | não | parcial |
| Modelo | dependência Hex | Hex privado, código fechado | dependência ou cópia | gera código no repo |
| Custo | grátis (MIT) | US$ 199–699, pagamento único | grátis | grátis |
| Maturidade | 4.17.1, release mensal, ~1,5 mi downloads | v3 | 1.0 (08/2026) | 0.0.x alpha |

Também foram consideradas live_react/live_svelte (shadcn de verdade dentro do
LiveView). Foram descartadas porque trazem Vite, npm e um segundo modelo de renderização.

## Decisão

Usar **petal_components** como sistema de design. Isso implica:

- remover o daisyUI e o `core_components.ex` gerado (um só sistema de design);
- Heroicons via o plugin Tailwind que o Phoenix já traz;
- tema com `primary` violeta e `secondary` sky, dark mode por classe.

## Consequências

- O catálogo cobre as telas do produto sem escrever componentes base.
- O código do Petal é dependência, então fica fora do Credo e da cobertura do projeto.
  Os warnings de tipo que ele gera ao compilar (e os de `phoenix_html_helpers`) são de
  terceiros e não quebram o `--warnings-as-errors`, que vale só para o nosso código.
- O Petal fixa `websock_adapter ~> 0.5.7`, e o projeto desceu da 0.7.0 para a 0.5.9.
  Vale reavaliar quando o Petal liberar a 0.7.
- O plugin `@tailwindcss/forms` é obrigatório.
- Plano B, se o acabamento visual não bastar: Fluxon UI para componentes pontuais.
