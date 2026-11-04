# 05 — Revisão de segurança: versão do runner no formato AAAA-MM-DD.NN

Escopo: `git diff main...HEAD` (Makefile, Dockerfile, `mix.exs`, `PipeMaestroProtocol.Version`
e `.Version.Git`, `PipeMaestro.Version`, `Runners.outdated?/2`, CLI do runner
`version`/`--version`, componentes `app_version` e `runner_version`, e2e).

**Veredito: sem risco grave. Nada bloqueia.** Há três observações de baixo risco, abaixo.

## O que foi verificado

### Canal do runner (entrada não confiável)
- `runner_version` continua validado em `PipeMaestroProtocol.Hello.text/2` (string de 1 a
  120 bytes) antes de ser gravado; a mudança não altera o protocolo nem a validação.
- `Version.parse/1` e `outdated?/2` tratam esse valor: regexes ancoradas e sem backtracking
  catastrófico, `String.to_integer/1` só sobre `\d` já casado (no máximo ~110 dígitos, pelo limite
  de 120 bytes), `Date.new/3` com retorno tratado, nenhum átomo criado. Qualquer valor fora do
  esquema cai em `:unknown` → `false`; `nil` é tratado. Um runner não consegue derrubar o render
  com uma versão malformada.
- Um runner que mente a versão só muda o próprio badge "desatualizado", no próprio workspace.
  Sem impacto em autorização.

### Injeção
- Tela: a versão do runner e a do control plane são renderizadas por HEEx (`{@version}`,
  `data-testid={...}`), com escape. Sem `raw/1`.
- Shell/git: `Version.Git` chama `System.cmd(git, ["-C", dir | args])` com lista de argumentos,
  sem shell; o `dir` é `__DIR__` (compilação) ou `File.cwd!()`. `mix.exs` idem.
- Makefile `runner.release`: a versão calculada é validada por
  `^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{2,}$` antes de entrar em `git tag -a`, e é usada entre aspas.
  O alvo recusa árvore suja e HEAD já tagueado; não faz push.
- `mix.exs` sanitiza a versão Burrito (`[^0-9A-Za-z.-]` → `-`).

### Autorização e isolamento entre workspaces
- Nenhuma rota, evento de LiveView ou consulta nova. `runner_version/1` recebe o `%Runner{}` que as
  LiveViews já carregavam escopado pelo workspace; `Runners.outdated?/2` não consulta o banco.
  Papéis admin/membro não são afetados.

### Segredos e dados sensíveis
- Nenhum segredo, token ou credencial nos novos caminhos. `pipemaestro status`/`doctor`/`start`
  passam a imprimir só a versão. `CP_VERSION` é um valor público por natureza.

## Observações de baixo risco (não bloqueiam)

1. **Versão exposta a não autenticados.** O `<footer>` do layout `public` (login, cadastro,
   ativação de runner) mostra a versão do control plane, que num build de dev inclui o commit
   curto (`…+dev.abc1234`). É divulgação de informação mínima e é o pedido da tarefa; em produção
   a imagem é construída de uma release tagueada (`make image`). Aceitável. Se quiserem reduzir a
   superfície, o layout `public` poderia omitir a versão.
2. **`pipemaestro version --next` existe no binário.** O plano dizia que `--next` não seria exposto
   no binário, mas `Commands.Version.run(["--next"])` é alcançável por `pipemaestro version --next`.
   Ele só roda `git -C <cwd> tag --list runner-*` e imprime uma string; `git tag --list` não executa
   hooks. Sem impacto de segurança; é uma divergência do plano para a revisão de código.
3. **`CP_VERSION` é usado como está.** Um valor com mais de 120 bytes faria o `Hello` do runner ser
   recusado (o runner não conecta). É controlado por quem compila, não por terceiros; no máximo uma
   falha de operação. Validar o formato ou o tamanho em `Version.Git.current/1` evitaria a surpresa.
