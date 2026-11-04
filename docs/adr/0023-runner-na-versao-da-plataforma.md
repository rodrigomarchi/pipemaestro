# 0023 — Runner na versão da plataforma

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

O runner roda na máquina de cada pessoa e só muda quando ela o atualiza. Um runner
antigo continuava conectando: no máximo ganhava o selo "desatualizado" na tela de
runners. Sem as mudanças mais novas do runner, ele pode, por exemplo, rodar uma análise
direto no diretório do usuário em vez de num worktree descartável (ADR 0021), ou
interpretar um campo novo do job de outro jeito.

Em produção, as versões são `dev+<commit>` (ADR 0016): commits não têm ordem, então
"mais velho que" não se decide pela versão. O deploy publica os binários do runner do
mesmo commit do control plane (ADR 0020).

## Decisão

- **Igualdade, não ordem.** Um runner só conecta se estiver exatamente na versão do
  control plane (`PipeMaestro.Runners.version_check/1`). Mais velho ou de outro build, é
  recusado.
- **Recusa no login e em todo (re)join.**
  - O device code responde `409` com `{"error": "outdated", "version",
    "runner_version", "download_url"}`.
  - O join do canal responde com o mesmo payload. Nada é gravado e o runner não fica
    online.
  - O `download_url` é a página dos binários publicados pelo deploy
    (`/downloads/runner/`).
- **O runner para e explica.** Ele cancela os jobs que roda, para não deixar o agente
  órfão (o control plane os conta como perdidos na próxima conexão), mostra as duas
  versões e o link, e sai sem tentar de novo.
- **Política por ambiente.** `config :pipe_maestro, :runner_version_policy`: `:exact` é
  o padrão (dev, e2e e produção), e os testes de unidade usam `:off`, porque as fixtures
  anunciam versões inventadas. Em dev, o runner do repositório e o servidor saem do
  mesmo checkout e têm a mesma versão; o e2e fixa as duas.

## Consequências

- Todo deploy exige atualizar os runners: o control plane reinicia, eles reconectam e
  são recusados até baixarem o binário novo. É o preço de não ter runner velho rodando.
- Em dev, um commit novo muda a versão: o runner precisa ser reiniciado junto com o
  servidor, e ele recompila na partida.
- O selo "desatualizado" segue no código, para runners gravados antes da regra.
