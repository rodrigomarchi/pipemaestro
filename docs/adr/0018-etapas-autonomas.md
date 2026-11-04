# 0018 — Etapas autônomas: permissões totais e sem aprovação entre etapas

- **Status:** aceita
- **Data:** 04/11/2026
- **Substitui:** os perfis de permissão do [ADR 0009](0009-permissoes-credencial-e-operacao-do-runner.md)
  e a aprovação ao fim da etapa do [ADR 0005](0005-pipelines-e-tarefas.md)

## Contexto

O control plane existe para levar uma tarefa até um PR sem alguém acompanhando cada
passo. Duas configurações de etapa iam contra isso.

- **Perfis de permissão** (`leitura`, `edicao` e `total`), com listas de ferramentas
  liberadas e negadas. Num run headless ninguém responde a um pedido de permissão, então
  tudo o que não estava liberado era negado. As etapas de leitura perdiam turnos com
  comandos negados (um `cat | head` encadeado, um `cd` no começo) e as de edição só
  rodavam o que alguém tinha previsto. Cada pipeline precisava de listas ajustadas à mão.
- **"Pedir aprovação humana ao terminar"** (`pause_after`): a tarefa parava entre
  duas etapas que tinham passado, à espera de um clique.

## Decisão

1. **Toda etapa roda com todas as permissões.** O runner sempre chama o CLI com
   `--dangerously-skip-permissions`.
   - A etapa não tem mais perfil nem listas de ferramentas, e o job do protocolo perdeu o
     campo `permissions`.
   - Um runner novo ignora o `permissions` que um control plane antigo ainda mande.
   - Um runner antigo, sem o campo, já roda com permissão total.
   - O que uma etapa não deve fazer (mudar código numa revisão, fazer commit) fica no
     prompt dela e no prompt de sistema do pipeline.
2. **Uma etapa que passa segue sozinha para a próxima.** Não existe mais aprovação de
   rotina entre etapas.
3. **A tarefa para quando precisa de ajuda**, e só nesses casos, como antes:
   - uma regra da etapa casa com a saída estruturada ("Pedir ajuda quando", ex.:
     `bem_definida == false`);
   - o agente termina como `bloqueado`;
   - as tentativas se esgotam;
   - o orçamento da tarefa estoura;
   - alguém pede uma pausa.

## Consequências

- **Dados antigos:** pipelines e tarefas guardam as etapas em jsonb. As chaves antigas
  (`pause_after`, `permission_profile`, `allowed_tools`, `denied_tools`) continuam lá e
  são ignoradas ao carregar. Uma tarefa em andamento segue sem pausar nem restringir.
  YAMLs exportados antes continuam importando.
- **Risco:** o risco do [ADR 0004](0004-execucao-de-jobs-no-runner.md) §4 (permissões
  totais na máquina do runner, sem container) deixa de ser provisório. Isolar a execução
  continua sendo a fase de containers.
- **Auditoria:** a auditoria de cada job ([ADR 0015](0015-auditoria-da-execucao.md))
  continua mostrando o modo de permissão que o CLI informou, agora sempre
  `bypassPermissions`. Uma negação que ainda apareça vem de algo fora do control plane,
  como as configurações do próprio repositório.
- **Formulário de pipeline:**
  - perdeu o seletor "O agente pode", as listas "Liberar também" e "Negar" e o
    checkbox de aprovação;
  - a regra de pausa passou a se chamar "Pedir ajuda quando".
