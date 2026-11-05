# E2E (Playwright)

Testes de tela num navegador real contra o servidor em `MIX_ENV=e2e`. A mesma
execução faz a auditoria visual: com `E2E_SHOTS`, cada spec salva screenshots
dos estados que importam, nos modos claro e escuro.

## Comandos

```bash
make e2e.install                      # primeira vez: deps npm + Chromium
make e2e                              # suíte inteira, headless
make e2e FILE=tests/user-session.spec.ts
make e2e.headed FILE=...              # navegador visível, em câmera lenta (SLOW_MO=300)
make e2e.ui                           # modo UI do Playwright, para depurar
make e2e.shots                        # suíte + screenshots claro/escuro (DARK=0 só claro)
make e2e.db.reset                     # recria o banco pipe_maestro_e2e
make e2e.typecheck                    # TypeScript das specs, Page Objects e helpers
```

O servidor sobe sozinho na porta `E2E_PORT` (padrão 4003), com o banco
`pipe_maestro_e2e` no Postgres de teste. Os alvos do Makefile matam
qualquer servidor que esteja na porta antes de rodar, para nunca validar código
antigo.

## Regras

- **Caixa-preta.** A única coisa criada fora do navegador é o operador inicial
  (`global-setup.ts`), pelo mesmo caminho da produção:
  `PipeMaestro.Release.create_operator/3`. Workspaces, usuários e outros
  operadores, cada spec cria pela interface, com nomes únicos (`uniqueSuffix()`),
  então as specs não dependem umas das outras nem de um banco limpo. A exceção é o
  diretor da landing (abaixo), que roda à parte, num banco recriado, com nomes fixos.
- **Seletores: só `data-testid`.** O frontend marca tudo o que um teste toca.
  Specs e Page Objects usam `page.getByTestId(...)`, sem texto, classe CSS,
  posição (`.first()`, `.nth()`) ou estrutura do DOM. Se um elemento não tem
  testid, o defeito está no template: acrescente lá.
- **Convenção de nomes**, em kebab-case:
  - elemento único na tela: `<coisa>` ou `<área>-<coisa>`, como `page-title`,
    `login-email` e `new-member-submit`;
  - elemento de um registro: `<coisa>-<chave natural>`, como
    `member-remove-ana@acme.dev` e `workspace-edit-acme`. A chave é o e-mail ou o
    slug, que a spec conhece, nunca o UUID;
  - a marca (`<Layouts.brand />`) leva `brand` e o símbolo `brand-mark`; quando há
    uma segunda na página (rodapé), `footer-brand` e `footer-brand-mark`;
  - os toasts ficam em `toasts`; confira o texto com `toContainText`.
- **Page Objects** em `pages/`: as specs leem como cenários, e as ações esperam
  a confirmação do servidor (toast ou página nova) em vez de usar sleeps.
- **Cada spec documenta seus fluxos** no cabeçalho `@section` / `@flow`.

## Evidência visual (`E2E_SHOTS`)

```ts
import { shot } from "../helpers/screenshots";

await backoffice.createWorkspace(name);
await shot(page, "workspace-created");             // página inteira
await shot(page.getByTestId("toasts"), "toast");   // um elemento
```

`shot()` não faz nada sem `E2E_SHOTS`, então a execução normal não muda.
Com `make e2e.shots`, as imagens ficam em
`e2e/screenshots/<spec>/<teste>/<nn>-<nome>[-dark].png`, numeradas na ordem
do fluxo, e também vão anexadas ao relatório HTML
(`cd e2e && npx playwright show-report`). A pasta está no gitignore.

Para conferir uma tela em largura estreita, a spec muda o viewport com
`page.setViewportSize` antes do `shot()` e o restaura depois (ver
`tests/job-execution.spec.ts`).

Nunca escreva uma spec descartável só para tirar um screenshot: ponha o
`shot()` na spec real do fluxo.

## Diretor da landing (`make landing.shots`)

As telas da landing (`/`) são screenshots reais da plataforma, gerados por um
**diretor**: `director/landing.spec.ts`, a exceção deliberada à regra acima. Ele monta
pela interface o workspace **Nimbus** (Marina Costa, o runner `macbook-marina` e o
diretório `loja-api`, em `director/scenario.ts`), com um runner real, e fotografa
`board`, `task`, `decision`, `audit`, `usage` e `runners`, claro e escuro, em
`apps/pipe_maestro_web/priv/static/images/landing/` (`<nome>.png` e
`<nome>-dark.png`, sempre os mesmos nomes).

```bash
make landing.shots    # APAGA o banco e2e deste worktree e regrava as imagens
```

- **Fora da suíte.** O projeto `director` do `playwright.config.ts` só existe com
  `E2E_DIRECTOR=1`; `make e2e` e `make e2e.shots` não o enxergam e não tocam nas imagens.
- **Quando rodar:** sempre que uma tela mostrada na landing mudar. Confira as imagens
  antes do commit; `PipeMaestroWeb.LandingShotsTest` falha se faltar uma, se o tamanho
  em pixels divergir do declarado em `PipeMaestroWeb.LandingShots` ou se passar de 600 KB.
- **Enquadramento:** `director/capture.ts` grava o viewport (1440×900, escala 2), com
  `top` para rolar uma área até logo abaixo do cabeçalho; esconde toasts e o caminho
  absoluto do worktree, e `retext` troca o que só esta máquina mostraria (hostname,
  endereço do servidor local).
- **O agente é o CLI de vitrine** `director/support/showcase_claude`, separado do
  `fake_claude` do runner (as specs dependem das saídas exatas dele). Imprime o mesmo
  `stream-json`, lê, edita arquivos do worktree e roda `make test`, escreve o artefato
  de cada etapa e exporta OTLP. O que cada tarefa faz vem do mapa de cenas
  (`SHOWCASE_SCENES`, linhas `frase|comportamento|módulo`, escrito pelo diretor):
  `ok`, `perguntas` (a primeira etapa para com duas perguntas) ou `segura:<etapa>`
  (a etapa fica rodando até existir `$SHOWCASE_DIR/release`, para a foto).
