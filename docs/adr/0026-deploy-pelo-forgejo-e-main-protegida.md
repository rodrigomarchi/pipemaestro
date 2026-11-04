# 0026 — Deploy pelo Forgejo e main protegida

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

O deploy era manual: alguém rodava `make deploy` numa máquina com acesso SSH ao Sun. A
`main` aceitava push direto. Com o PipeMaestro desenvolvendo o próprio PipeMaestro, as
mudanças passam a chegar por branches de tarefas, e o caminho até a produção precisa ser
o mesmo para todas: um pull request revisado, e o merge publicando sozinho.

O Forgejo (Moon) estava com o Actions desligado e sem runner.

## Decisão

- **A `main` só muda por pull request.** A proteção da branch no Forgejo recusa push
  direto para todos, inclusive admins (`apply_to_admins`), e não exige aprovação
  (o dono é o único revisor). Ela vem da infra (`forgejo_ci_repos`, `protect_main`).
- **O merge publica.** `.forgejo/workflows/deploy.yml` roda em push na `main`, ou à mão
  (`workflow_dispatch`), e chama `scripts/deploy_sun.sh main`, o mesmo do deploy manual.
- **O runner fica no Moon, preso a este repositório.** A role `forgejo_runner` da infra
  registra um runner com escopo `rodrigomarchi/pipemaestro`: workflows de outros
  repositórios não rodam nele. Os jobs rodam em containers do Docker do Moon, sem acesso
  a esse Docker.
- **O runner entra no Sun por uma chave que não abre shell.** A chave é gerada no Moon e
  vai para o Forgejo como secret do repositório. A chave de host do Sun também vai,
  lida no próprio Sun, então não há confiança no primeiro uso. No `authorized_keys` do
  usuário de deploy, a chave fica presa (`command=...,restrict`) a
  `~/bin/pipemaestro-deploy` (role `deploy_access`), que:
  - só aceita `deploy <branch>`;
  - busca o clone;
  - roda o `scripts/deploy.sh` daquela branch;
  - faz um deploy por vez (`flock`).

  O deploy manual passa pelo mesmo script.
- **Sem CI obrigatório nos PRs, por enquanto.** O `make ci` roda nas etapas dos
  pipelines do PipeMaestro e localmente. Exigir o check no merge pede um runner que rode
  Postgres e Dialyzer a cada PR. Fica para quando o volume de PRs pedir.

## Consequências

- Um merge na `main` vai para produção em minutos. Reverter é outro PR (um revert) ou o
  deploy manual de uma ref anterior.
- Quem tem a chave do runner só consegue publicar uma branch que já está no Forgejo. O
  que roda é o código dessa branch, a mesma confiança do deploy manual.
- O Forgejo fora do ar adia os deploys, como já adiava o build do servidor, que clona
  dele.
- Outro repositório entra no mesmo esquema acrescentando-o a `forgejo_ci_repos`, na
  infra.
