A plataforma separa quem **coordena** de quem **executa**. O control plane, na nuvem,
guarda pipelines e decide o próximo passo. O runner, na sua máquina, faz o trabalho no seu
código.

## O que fica na sua máquina

- **O código.** O runner trabalha num worktree do diretório do projeto. A plataforma vê o
  que o agente relata (artefatos, os nomes dos arquivos mudados, a saída das ferramentas),
  não o repositório.
- **O login do Claude.** O agente roda com a conta de quem roda o runner. A plataforma não
  recebe a credencial.
- **A rede fechada.** O runner abre a conexão de saída; nenhuma porta de entrada precisa
  ficar aberta.

## O que fica no control plane

- Pipelines, projetos, tarefas, artefatos e o registro de cada execução.
- **Segredos** do workspace (o token de um servidor MCP, uma conta de teste): cifrados,
  entregues ao runner só em memória, a cada execução, e nunca mostrados de volta.
- As credenciais das integrações, também cifradas.

## Isolamento

- Cada tarefa tem o próprio worktree e o próprio branch.
- Uma etapa só passa pelos gates do projeto: os seus testes, não a opinião do agente.
- O merge só é automático num pipeline em que alguém ligou essa opção. Por padrão, o PR
  espera a sua revisão. O deploy nunca é feito pela plataforma.

## Quem pode o quê

| Papel | Pode |
|---|---|
| Membro | criar e acompanhar tarefas, decidir quando elas param, cancelar as próprias |
| Administrador | também gerenciar pipelines, projetos, runners (aprovar, renomear, revogar), integrações e segredos, cancelar qualquer tarefa e ver a auditoria |

Na issue, só quem tem permissão de escrita no repositório dispara tarefas e manda comandos,
a menos que um gatilho aceite qualquer pessoa (com triagem e confirmação).

## Runners

- Um runner entra pelo código de oito letras confirmado no navegador, e cada um tem a
  própria credencial.
- Revogar o runner desconecta o executável na hora.
- A plataforma recusa um runner numa versão diferente da exigida; a atualização é
  automática.

## Retenção

O conteúdo dos anexos, os eventos completos do agente e os logs dos runners ficam pelo prazo
de retenção do workspace e depois são apagados.
