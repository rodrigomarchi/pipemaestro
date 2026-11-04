# UI com petal_components

As telas usam [petal_components](https://petal.build/components) sobre Tailwind v4.
A escolha e as alternativas avaliadas estão no
[ADR 0001](../adr/0001-biblioteca-de-componentes.md).

## Regras

- **Use um componente Petal antes de escrever markup Tailwind.** Botão, input, tabela,
  modal, dropdown, badge, card, tabs, toast, timeline, stepper, sidebar, data table:
  todos existem. `use PetalComponents` (em `html_helpers/0` de
  `ClaudeControlPlaneWeb`) importa todos como `<.button>`, `<.card>` etc.
- **Confira os attrs e slots antes de usar.** Não invente atributos de memória: cada
  componente declara `attr`/`slot` em `lib/petal_components/*.ex`. O `.claude/settings.json`
  bloqueia a leitura de `deps/`; para ler o código, baixe o pacote:
  `mix hex.package fetch petal_components <versão> --unpack --output <dir>`.
  O pacote traz `rules.md`, as regras oficiais do Petal para agentes.
- **Formulários:** `<.field field={@form[:x]} type="..." label="..." />` para o caso comum
  (label, input, erro e ajuda juntos); os primitivos (`<.text_input>`, `<.select>`…) só
  quando o layout do campo for próprio.
- **Flash** vira toast via `<.toast_group flash={@flash} />`, chamado apenas nos layouts.
- **Ícones:** `<.icon name="hero-…" />` (Heroicons via o plugin em `assets/vendor/heroicons.js`).
- **Layouts:** `<Layouts.app>` para telas autenticadas (sidebar + top bar) e
  `<Layouts.public>` para landing e login.

## Tema

- **Cores:** `primary` é violeta e `secondary` é sky, definidos em `@theme inline`
  no `assets/css/app.css`. Os papéis `info`, `success`, `warning`, `danger` e `gray`
  usam os padrões do Petal (`gray` = zinc).
- **Dark mode:** classe `dark` no `<html>`, aplicada por `<.color_scheme_script />` no
  root layout antes do primeiro paint. Use `dark:` normalmente; a troca é feita por
  `<.color_scheme_switch>`.

## Integração (o que não é óbvio)

- `@plugin "@tailwindcss/forms"` é obrigatório: as classes `pc-*` de input só definem
  cor e raio e contam com o plugin para borda, padding e altura. Ele já vem no binário
  standalone do Tailwind, então não precisa de npm.
- Os hooks JS são registrados de uma vez em `assets/js/app.js`
  (`hooks: {...colocatedHooks, ...PetalComponents}`).
- `<.chart>` exige ECharts (`window.echarts`), que ainda não foi incluído. `<.sparkline>`
  é SVG renderizado no servidor e não precisa de nada.
- `mdex` e `eqrcode` são dependências opcionais do Petal e não estão instaladas: os
  componentes `Chat.markdown` e `<.qr_code>` não funcionam sem elas.
- Um componente local com o nome de um do Petal colide com o import de
  `use PetalComponents`. O módulo que define o seu desfaz o do Petal com
  `import PetalComponents.<Módulo>, only: []` (é o caso de `timeline/1` em
  `JobComponents`).
- O Petal fixa `websock_adapter ~> 0.5.7`, o que mantém o projeto na 0.5.x em vez da 0.7.
