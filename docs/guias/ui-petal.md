# UI com petal_components

As telas usam [petal_components](https://petal.build/components) sobre Tailwind v4.
A escolha e as alternativas avaliadas estão no
[ADR 0001](../adr/0001-biblioteca-de-componentes.md).

## Regras

- **Use um componente Petal antes de escrever markup Tailwind.** Botão, input, tabela,
  modal, dropdown, badge, card, tabs, toast, timeline, stepper, sidebar, data table:
  todos existem. `use PetalComponents` (em `html_helpers/0` de
  `PipeMaestroWeb`) importa todos como `<.button>`, `<.card>` etc.
- **Confira os attrs e slots antes de usar.** Não invente atributos de memória: cada
  componente declara `attr`/`slot` em `lib/petal_components/*.ex`. O `.claude/settings.json`
  bloqueia a leitura de `deps/`; para ler o código, baixe o pacote:
  `mix hex.package fetch petal_components <versão> --unpack --output <dir>`.
  O pacote traz `rules.md`, as regras oficiais do Petal para agentes.
- **Formulários seguem um padrão só** (`PipeMaestroWeb.FormComponents`, importado
  em todas as telas):
  - **todo campo tem ícone:** `<.icon_field field={@form[:x]} icon="hero-…" label="..." />`
    em vez de `<.field>`. Ele recebe os mesmos attrs, e o rótulo do Petal continua no HTML
    para leitores de tela. Um controle compacto (filtro, select na linha de uma tabela) usa
    `hide_label`, e um controle que não é `<.field>` (combo box) leva `<.icon_label>`;
  - **todo texto que o agente ou uma pessoa lê como Markdown** (prompts, instruções,
    notas, mensagens) usa `<.markdown_editor id=... field=... label=... testid=... />`,
    com barra de formatação, menu de variáveis (`variables`) e preview. O textarea
    continua sendo o input real, com o `data-testid` de sempre;
  - **formulários longos se dividem em seções**, cada uma num card com `<.section_heading>`,
    e os blocos dentro delas com `<.block_heading>`, todos com ícone.

  Os primitivos (`<.text_input>`, `<.select>`…) ficam para quando o layout do campo for
  próprio.
- **Flash** vira toast via `<.toast_group flash={@flash} />`, chamado apenas nos layouts.
- **Ícones:** `<.icon name="hero-…" />` (Heroicons via o plugin em `assets/vendor/heroicons.js`).
- **Layouts:** `<Layouts.app>` para telas autenticadas (sidebar + top bar) e
  `<Layouts.public>` para landing e login.

## Cartões selecionáveis (radio e checkbox)

O questionário de decisão (`PipeMaestroWeb.QuestionnaireLive`, com as partes em modo
leitura em `PipeMaestroWeb.QuestionnaireComponents`) usa opções como cartões:

- um `<label>` com borda, que leva o `data-testid` da opção, e dentro dele um
  `<input type="radio|checkbox" class="sr-only">` e o texto;
- o estado vem do CSS, sem JS: `has-[:checked]:border-primary-500 has-[:checked]:bg-primary-50`
  e os equivalentes `dark:`;
- um `<input type="hidden" value="">` com o mesmo nome garante que o campo chegue mesmo
  sem nenhuma opção marcada;
- a grade é `grid sm:grid-cols-2`: uma coluna no celular.

O `radio_card` do Petal (`<.field type="radio-card">`) exige um campo de formulário e não
cobre checkbox, por isso o padrão acima.

Um `<details>` que a tela atualiza ao vivo perde o `open` a cada patch. Dê a ele um `id`
estável e `phx-mounted={JS.ignore_attributes(["open"])}` (é o caso de "Decidir sem
responder" no painel da tarefa).

## Marca

O símbolo do PipeMaestro é desenho próprio e agnóstico de fornecedor
([ADR 0019](../adr/0019-o-nome-pipemaestro.md)): três agentes (os pontos à esquerda)
convergem num único pipeline, que passa por uma etapa (o anel) e termina no pull request
(o ponto cheio). É o maestro do pipeline, não o de um agente.

- **Componentes:** `<Layouts.brand />` é a marca com nome (attrs `size` `"sm"`/`"md"` e
  `compact` para a sidebar, em que só o nome some ao recolher); `logo_mark/1`
  (`PipeMaestroWeb.BrandComponents`) é só o símbolo, dimensionado por `class`. O fundo é
  CSS no próprio `<svg>` e os traços seguem `currentColor`, então várias marcas na mesma
  página não disputam ids.
- **Test ids:** o link da marca leva `brand` e o símbolo `brand-mark`. Onde a marca
  aparece duas vezes na mesma página (nav e rodapé da landing), a segunda passa o attr
  `testid` (`footer-brand`, símbolo `footer-brand-mark`), para as specs não precisarem
  de `.first()`.
- **Arquivos** em `apps/pipe_maestro_web/priv/static/images/`: `logo-mark.svg` (em cor),
  `logo-mark-mono.svg` (só traços em `currentColor`, sem fundo, para qualquer cor de
  fundo) e `favicon.svg` (desenho simplificado para 16–32 px). O `priv/static/favicon.ico`
  (16/32/48) é rasterizado do `favicon.svg`; o `root.html.heex` declara os dois.
- **Regras:** o gradiente é só `primary-500` → `secondary-500`; não recolorir com cores
  de terceiros nem acrescentar símbolo, nome ou faísca de fornecedor; tamanho mínimo de
  16 px, e abaixo de 24 px usar o desenho do favicon; deixar ao redor um respiro de pelo
  menos um quarto do lado do símbolo; sem texto dentro do símbolo.

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
