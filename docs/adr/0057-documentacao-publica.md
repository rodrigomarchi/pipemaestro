# 0057 — Documentação pública

- **Status:** aceita
- **Data:** 11/11/2026
- **Relacionadas:** [ADR 0001](0001-biblioteca-de-componentes.md)

## Contexto

A plataforma tinha uma página pública só, a landing. Quem chegava não achava como começar,
como cada peça funciona nem exemplos de uso, e a landing ficou para trás das telas: dizia
que a plataforma nunca faz o merge, quando o merge automático já existia, e não citava as
integrações, as propostas do agente nem a qualidade das entregas. Os guias de `docs/` são
para quem opera ou desenvolve a plataforma, não para quem a usa.

## Decisões

1. **As páginas são Markdown em `apps/pipe_maestro_web/priv/docs/<slug>.md`**, lidas e
   renderizadas quando `PipeMaestroWeb.Docs` compila, com o MDEx que o app já usa para os
   artefatos. Escrever uma página não pede HEEx, e o servidor não lê disco a cada visita.
   O índice (seções, títulos, descrições e ordem de leitura) fica em `PipeMaestroWeb.Docs`.
2. **Rotas públicas `/docs` e `/docs/:slug`** (`PipeMaestroWeb.DocsController`), no layout
   público, com o índice ao lado da página (num menu dobrável no celular) e os links para a
   página anterior e a próxima. Um slug desconhecido é 404.
3. **Screenshots reais nas páginas:** uma linha só com `{{tela:<nome>}}` põe uma tela de
   `PipeMaestroWeb.LandingShots` (claro e escuro), e um nome desconhecido falha a
   compilação. As telas que só as docs mostram (`LandingShots.docs/0`) são fotografadas
   pelo mesmo diretor da landing (`make landing.shots`).
4. **O HTML cru do Markdown não é renderizado** (`unsafe: false`), como nos artefatos: o
   conteúdo é nosso, mas não há motivo para abrir essa porta.
5. **A landing aponta para as docs**: "Exemplos" e "Documentação" no menu, os exemplos do
   dia a dia numa seção própria e cada recurso com um "Saiba mais".

## Consequências

- Mudar uma tela mostrada nas docs pede `make landing.shots`, como já pedia na landing.
- Uma página nova é um arquivo em `priv/docs/` e uma linha no índice de
  `PipeMaestroWeb.Docs`; o ExUnit confere que todo link interno leva a uma página que
  existe.
- O conteúdo descreve o produto e envelhece com ele: uma mudança de comportamento visível
  ao usuário revisa a página correspondente.
