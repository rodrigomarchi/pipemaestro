# claude_control_plane

Plataforma SaaS que conduz tarefas de engenharia (issues do GitHub) por um pipeline
determinístico de agentes de IA até um Pull Request pronto para revisão humana.

- Visão e arquitetura: [`docs/plano/01-visao-arquitetura.md`](docs/plano/01-visao-arquitetura.md)
- Contexto de discovery: [`docs/plano/02-contexto-discovery.md`](docs/plano/02-contexto-discovery.md)
- Convenções e gate de qualidade: [`AGENTS.md`](AGENTS.md)

## Estrutura

| App | Papel |
|---|---|
| [`apps/claude_control_plane`](apps/claude_control_plane) | Domínio do control plane (sem camada web) |
| [`apps/claude_control_plane_web`](apps/claude_control_plane_web) | Phoenix + LiveView + Channels dos executores |
| [`apps/claude_control_plane_protocol`](apps/claude_control_plane_protocol) | Contrato executor ↔ control plane |
| [`apps/claude_control_plane_runner`](apps/claude_control_plane_runner) | Executor BYO (release própria) |

## Começando

Requer asdf (versões em `.tool-versions`) e Docker.

```bash
make setup        # Postgres (dev 5442, test 5443) + deps + banco + assets
make db.migrate   # depois de puxar migrações novas
make server       # http://localhost:4000
make ci       # o gate: compile sem warnings, format, credo, testes com cobertura, dialyzer
```

Em dev, `make setup` roda os seeds e imprime as credenciais de dev (um operador
e dois usuários em dois workspaces).

### Primeiro operador do backoffice

Sem operador, ninguém entra no backoffice. Em dev:

```bash
mix control_plane.create_operator ops@empresa.com "Nome"
```

Numa release:

```bash
bin/claude_control_plane eval 'ClaudeControlPlane.Release.migrate()'
bin/claude_control_plane eval 'ClaudeControlPlane.Release.create_operator("ops@empresa.com", "Nome", "senha longa")'
```

### Runner

Para instalar em produção e em outras máquinas (imagem do control plane, `cp-runner`,
TLS, primeiro pipeline), veja [`docs/guias/instalacao.md`](docs/guias/instalacao.md).

```bash
make runner.login URL=http://localhost:4000   # mostra um código; aprove no navegador
make runner.start ROOT=~/src                  # fica online oferecendo os diretórios de ~/src (Ctrl+C para parar)
make runner.doctor                            # confere claude, credencial, git, raiz, disco e plataforma
make runner.service ACTION=install            # roda em segundo plano (launchd/systemd), log em runner.log
make runner.status                            # credenciais e se a plataforma ainda aceita
make runner.logout                            # remove as credenciais locais
```

Opções do login: `NAME=...`, `LABELS="gpu cuda"`, `CAPACITY=N` (jobs ao mesmo tempo).
O agente usa o login do `claude` da máquina; com `RUNNER_ANTHROPIC_API_KEY` no
ambiente do runner, usa essa chave. Na plataforma, os
runners ficam em **Executores** (`/w/<workspace>/runners`). O protocolo está em
[`docs/specs/protocolo-runner.md`](docs/specs/protocolo-runner.md).

Com o runner online, em **Execuções** (`/w/<workspace>/jobs`) um prompt enviado a ele
roda no `claude` da máquina do runner (`claude -p`, com permissões totais), dentro do
workdir `~/.config/claude-control-plane/workdir/`, e a execução aparece ao vivo.
`CLAUDE_BIN=...` troca o executável (os testes usam
`apps/claude_control_plane_runner/test/support/fake_claude`).

Em **Tarefas** (`/w/<workspace>/tasks`), uma tarefa percorre as etapas de um
**Pipeline** (`/w/<workspace>/pipelines`; "Criar pipelines padrão" traz "Prompt único"
e "Correção de bug") num dos diretórios que o runner oferece. Num repositório git,
cada tarefa ganha um worktree próprio em
`~/.config/claude-control-plane/workdir/worktrees/<tarefa>`, e o seu checkout não é
tocado. Cada etapa grava um artefato em `.control-plane/<tarefa>/`. Quando uma etapa
bloqueia ou esgota as tentativas, a tarefa espera uma decisão na tela. O `ROOT` fica
salvo, então os próximos `make runner.start` não precisam dele.

### Testes de tela

```bash
make e2e.install   # primeira vez
make e2e           # Playwright, navegador real
make e2e.shots     # mesma suíte + screenshots claro/escuro em e2e/screenshots/
```

Detalhes em [`e2e/README.md`](e2e/README.md).

`make help` lista todos os alvos.
