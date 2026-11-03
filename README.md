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

`make help` lista todos os alvos.
