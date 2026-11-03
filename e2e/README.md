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
make e2e.db.reset                     # recria o banco claude_control_plane_e2e
make e2e.typecheck                    # TypeScript das specs, Page Objects e helpers
```

O servidor sobe sozinho na porta `E2E_PORT` (padrão 4003), com o banco
`claude_control_plane_e2e` no Postgres de teste. Os alvos do Makefile matam
qualquer servidor que esteja na porta antes de rodar, para nunca validar código
antigo.

## Regras

- **Caixa-preta.** A única coisa criada fora do navegador é o operador inicial
  (`global-setup.ts`), pelo mesmo caminho da produção:
  `ClaudeControlPlane.Release.create_operator/3`. Workspaces, usuários e outros
  operadores, cada spec cria pela interface, com nomes únicos (`uniqueSuffix()`),
  então as specs não dependem umas das outras nem de um banco limpo.
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

Nunca escreva uma spec descartável só para tirar um screenshot: ponha o
`shot()` na spec real do fluxo.
