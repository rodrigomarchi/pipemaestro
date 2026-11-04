# 0019 — O nome PipeMaestro

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

O projeto nasceu como "Claude Control Plane". O nome amarrava a plataforma a um
único agente, mas o que ela faz é conduzir qualquer agente de IA por um pipeline
de etapas, e outros agentes devem poder rodar nela. A escolha passou pela
disponibilidade de domínio (`.com`, `.dev`, `.ai`, `.io`), pelo nome no GitHub e
por uma busca de produtos com o mesmo nome.

## Decisão

O projeto passa a se chamar **PipeMaestro**: o maestro do pipeline.

| Antes | Depois |
|---|---|
| módulos `ClaudeControlPlane*` | `PipeMaestro`, `PipeMaestroWeb`, `PipeMaestroProtocol`, `PipeMaestroRunner` |
| apps `apps/claude_control_plane*` | `apps/pipe_maestro*` |
| CLI do runner `cp-runner` | `pipemaestro` (binário `pipemaestro_<alvo>`) |
| config do runner `~/.config/claude-control-plane` | `~/.config/pipemaestro` |
| serviço `com.claude-control-plane.runner` / `claude-control-plane-runner.service` | `com.pipemaestro.runner` / `pipemaestro-runner.service` |
| bancos `claude_control_plane_*` | `pipe_maestro_*` |
| imagem Docker `claude-control-plane` | `pipemaestro` |

**Continuam iguais.** Nenhum destes nomes fala do Claude:

- "control plane", como termo de arquitetura;
- o agente Claude Code, que segue sendo o agente que o runner executa;
- `CP_ARTIFACT_PATH`, `CP_VERSION` e o atributo `cp.job_id`;
- o prefixo de branch `cp/` e a pasta `.control-plane/` dos artefatos.

## Consequências

- **O protocolo não carrega o nome do produto**, então ele não mudou.
- **Recomeço do zero.** O projeto era novo e só tinha uma instalação de desenvolvimento,
  então nada do nome antigo foi mantido por compatibilidade:
  - os bancos e os volumes Docker foram recriados;
  - o runner fez login de novo, já em `~/.config/pipemaestro`;
  - os binários e caches antigos foram apagados.
- **Nome do projeto no Compose.** O `docker-compose.yml` fixa `name: pipemaestro`, e os
  volumes deixam de depender do nome da pasta do checkout.
- **Sessões:** o cookie da sessão mudou de nome, então quem estava logado entra de novo.
