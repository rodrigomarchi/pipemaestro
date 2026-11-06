# 0035 — Versão própria do runner

- **Status:** aceita
- **Data:** 05/11/2026
- **Supera em parte:** [ADR 0023](0023-runner-na-versao-da-plataforma.md) (a versão
  exigida); ajusta a [ADR 0016](0016-esquema-de-versao.md) (duas versões) e a
  [ADR 0020](0020-binarios-do-runner-no-deploy.md) (quando os binários são gerados).

## Contexto

Até aqui o runner e o control plane tinham a mesma versão, calculada do `HEAD` do
checkout (ADR 0016), e o control plane só aceitava o runner nessa versão (ADR 0023).
Qualquer commit (uma tela, uma migração, um texto da landing) mudava a versão. Todo
runner era recusado e precisava se atualizar, mesmo quando o binário novo tinha
exatamente o mesmo código. O deploy também reconstruía os quatro binários Burrito a
cada vez.

O Burrito não tem mecanismo de versão nem de atualização: ele só empacota a release.
Os projetos que distribuem um binário único versionam o binário independente do
servidor, publicam um binário novo só quando ele muda, e o servidor decide quem
aceita por um contrato de compatibilidade, nunca pelo commit do servidor.

## Decisão

- **A versão do runner é a do último commit que mudou o que entra no binário dele.**
  `PipeMaestroProtocol.Version.Git.runner/1` aplica o esquema da ADR 0016 ao commit
  `git log -1 -- <caminhos>`, a partir da raiz do repositório. Se esse commit tem uma
  tag `runner-*`, a versão é a da tag. Senão é `<maior tag alcançável>+dev.<commit>` ou
  `dev+<commit>`. Sem git, é `dev+unknown`. O formato não muda.
- **Os caminhos são uma lista fixa e conservadora**
  (`PipeMaestroProtocol.Version.Git.runner_paths/0`): o app do runner, os apps do
  umbrella de que ele depende e as entradas do build (configuração, `mix.exs`,
  `mix.lock`, `.tool-versions`, a imagem e o script do build dos binários). Na dúvida,
  um caminho entra: o custo é uma atualização a mais. Um teste falha se um app de que o
  runner depende ficar fora da lista.
- **O control plane tem duas versões.** A dele, do `HEAD`, aparece no rodapé e no
  `/version`. A versão de runner que ele exige (`PipeMaestro.Version.runner_version/0`)
  é calculada do mesmo checkout na compilação. `PipeMaestro.Runners.version_check/1`
  compara o runner com ela, **por igualdade**, como na ADR 0023.
- **Variáveis por ambiente.** `CP_VERSION` vale só para o control plane e
  `RUNNER_VERSION` para o runner. A imagem Docker recebe as duas (`make image`), e o e2e
  fixa as duas, com valores diferentes.
- **O deploy só gera os binários quando a versão do runner muda.** O diretório
  publicado tem um `VERSION` com a versão de runner dos binários. Quando ele é igual à
  do commit, o `scripts/deploy.sh` não gera os binários de novo.
- **O protocolo não muda de formato.** O `"version"` do payload `"outdated"` passa a
  ser a versão de runner exigida, não a do control plane. `protocol_version` não sobe.

## Alternativa descartada

**Versão mínima ou janela de compatibilidade por ordem de versão.** Em produção as
versões são `dev+<commit>`, que não têm ordem (ADR 0023). Afrouxar a igualdade abriria
de novo o risco de um runner velho rodando, que motivou a ADR 0023.

## Consequências

- Um deploy que não mexe no runner (web, domínio, telas, migrações, docs) não pede
  atualização: os runners reconectam quando o control plane reinicia e voltam online
  sozinhos. O deploy fica mais rápido.
- Um deploy que mexe no runner continua pedindo a atualização, pelo fluxo da
  [ADR 0025](0025-atualizacao-automatica-do-runner.md).
- **Runner antigo:** ele anuncia `dev+<HEAD antigo>`, que difere da versão de runner
  nova, então é recusado uma última vez, com o payload de sempre, e se atualiza. A
  partir daí os deploys que não tocam o runner não o recusam mais. Nessa transição, o
  texto do runner antigo ainda diz "a plataforma está na X", com X sendo a versão do
  runner.
- Um caminho que muda o binário e ficou fora da lista deixaria conectar um runner
  antigo. Por isso a lista é conservadora e tem um teste.
- O servidor precisa de um clone completo. Num clone raso, o `git log -- <caminhos>`
  não acharia o commit certo.
