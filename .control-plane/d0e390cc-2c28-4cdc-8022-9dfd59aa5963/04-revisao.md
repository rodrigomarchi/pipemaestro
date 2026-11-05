# Revisão de convenções — O projeto como a única escolha de onde o trabalho roda

## Resultado

| Verificação | Resultado |
|---|---|
| `make ci.quick` | sai 0 |
| `make e2e.typecheck` | passa |
| `make e2e` | todas as specs passam |
| `make e2e.shots` | passa; telas de projetos (lista, formulário, proposta) e tarefa auditadas, claro e escuro |

## O que a revisão encontrou

- **Plano não cumprido: Playwright.** A etapa 3 deixou os specs na API antiga. Migrados para
  projeto (runner + pasta): `task-pipeline`, `decision-questionnaire`, `board-alerts`,
  `agent-proposals`, `pipeline-proposal`, `job-execution`, `runner-connection` e o diretor da
  landing. Todos sobem o runner com `--root` e criam o projeto antes de disparar trabalho.
  - `job-execution`: a execução solta roda num worktree descartável; a asserção do
    `fake-claude.txt` no workdir virou "o arquivo nunca chega à pasta do projeto".
  - `pipeline-proposal`: o projeto é criado antes; a proposta só abre o formulário do pipeline
    (`proposal-open-pipeline`) e não mexe no projeto.
  - `task-pipeline` (fluxo G): o projeto `App` existe desde o começo e o fluxo o edita
    (`ProjectsPage.configure`), já que `(runner, pasta)` é único.
  - `ProposalPage.submitRequest`: o switch do Petal esconde o input (sr-only); o clique forçado
    falhava com "fora da viewport" no modal recém-aberto; passou a alternar pelo teclado.
- Sem achados em: `@spec`/`@moduledoc` do código novo, LiveViews finas, comentários que narram a
  mudança, `handle_info` catch-all, fronteiras do umbrella (runner só depende de `protocol`),
  exclusões de cobertura, contagens na prosa.

## Critérios de aceite

Os 14 critérios têm teste de domínio ou de LiveView (etapas 2–3); os fluxos de tela (criar à mão e
com IA, trocar runner, nova tarefa por projeto, execução solta, propostas) agora também têm e2e.

## Pendências

Nenhuma.
