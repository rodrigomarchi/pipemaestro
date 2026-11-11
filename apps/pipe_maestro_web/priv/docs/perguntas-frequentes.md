## Preciso de uma conta do Claude?

Sim. O agente é o Claude Code, que roda na máquina do runner com o login de quem o roda. O
uso (e a cobrança) do Claude é da sua conta. A plataforma mostra o custo de cada execução e
avisa quando a conta chega perto do limite.

## Quanto custa uma tarefa?

Depende do pedido, do pipeline e dos modelos. O Uso mostra o custo por tarefa, etapa,
pipeline e pessoa. Para pôr um limite, defina um **teto de custo por tarefa** no pipeline (a
tarefa pausa quando passa dele) ou um orçamento por etapa.

## Funciona com qualquer linguagem?

Sim. O agente usa os comandos de setup, teste e lint que você define no projeto, sejam eles
`make test`, `npm test`, `pytest` ou `mvn verify`. O runner precisa do git e do CLI do
agente, e do `gh` autenticado para entregar PRs no GitHub.

## O agente pode quebrar o meu repositório?

Ele trabalha num worktree separado, num branch próprio. O seu diretório de trabalho não é
tocado, e nada chega à branch principal sem um PR, que por padrão espera a sua revisão.

## Posso usar mais de uma máquina?

Sim. Conecte quantos runners quiser; cada projeto diz em qual runner o código vive. Cada
runner roda várias tarefas ao mesmo tempo, até a capacidade dele.

## E se o runner desligar no meio de uma tarefa?

A etapa aparece como perdida e, quando o runner volta, roda de novo na mesma tentativa, sem
gastar uma nova. Um runner offline aparece no board e na página da tarefa.

## O agente parou. E agora?

Abra a tarefa: o aviso sobre o pipeline leva à etapa que espera. Responda às perguntas,
refaça com instruções, siga ou cancele. Veja [Decisões](/docs/decisoes).

## Como o agente conhece as convenções do meu projeto?

Pelo `CLAUDE.md` ou pelo `AGENTS.md` do repositório, que toda etapa lê, e pelas notas para
os agentes do projeto. Instruções que valem para todos os projetos vão no prompt de
sistema do pipeline.

## Dá para usar ferramentas externas (logs, tickets, banco)?

Sim, por servidores MCP configurados no pipeline. Os tokens ficam em Segredos e chegam ao
runner só durante a execução.

## Posso trazer os meus próprios pipelines?

Sim. Edite os prontos no diagrama, crie do zero, importe um YAML ou peça ao agente que
proponha um a partir do seu código.

## Uma tarefa pode continuar depois de concluída?

Sim. **Mensagem para a tarefa** roda uma nova etapa de correção no mesmo worktree. Pela
issue, `/pipemaestro corrigir <pedido>` faz o mesmo, e um review pedindo mudanças no PR
também.
