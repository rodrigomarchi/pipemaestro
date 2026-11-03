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
make setup    # Postgres (dev 5442, test 5443) + deps + banco + assets
make server   # http://localhost:4000
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

### Testes de tela

```bash
make e2e.install   # primeira vez
make e2e           # Playwright, navegador real
make e2e.shots     # mesma suíte + screenshots claro/escuro em e2e/screenshots/
```

Detalhes em [`e2e/README.md`](e2e/README.md).

`make help` lista todos os alvos.
