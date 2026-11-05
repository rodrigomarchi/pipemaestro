# 0034 — O projeto é runner + pasta e a escolha única de onde o trabalho roda

- **Status:** aceita
- **Data:** 05/11/2026
- **Complementa:** [ADR 0008](0008-projetos-gates-e-feedback.md) (o projeto era a
  configuração de um nome de pasta, casado em qualquer runner)
- **Relacionadas:** [ADR 0021](0021-propostas-de-pipeline-pelo-agente.md) e
  [ADR 0022](0022-propostas-do-agente-como-mecanismo-geral.md) (propostas), [ADR 0032](0032-sem-ruas-sem-saida.md)
  (troca de runner da tarefa)

## Contexto

Quem disparava trabalho escolhia à mão um runner e uma pasta dele, em cada tela: nova
tarefa, execução solta, tarefa escrita com IA, proposta de pipeline. O projeto ficava
implícito: a tarefa procurava em silêncio o projeto da pasta pelo nome, e o gatilho do
GitHub escolhia qualquer runner online que oferecesse a pasta. A mesma pasta não podia ser
dois projetos, e uma execução solta rodava no `workdir` do runner, fora de qualquer projeto.

## Decisão

1. **Projeto = runner + pasta + configuração.** `projects.runner_id` aponta um runner do
   workspace, e a pasta tem de ser uma das que ele anuncia. A mesma pasta pode ser projeto
   em runners diferentes (`app` no notebook e `app` no servidor); a unicidade é
   `(workspace, runner, pasta)`. O `github_repo` passa a ser único por workspace, para o
   gatilho não ficar ambíguo entre dois projetos da mesma pasta.
2. **O projeto é a única escolha de quem dispara trabalho.** Nova tarefa, execução solta,
   tarefa escrita com IA, propostas de pipeline e de melhoria e o gatilho do GitHub recebem
   só o projeto; runner, pasta, `git` e o retrato saem dele. Não existe trabalho sem
   projeto. As propostas sobre uma tarefa (decisão, análise) seguem o runner e a pasta da
   própria tarefa.
3. **Execução solta sempre em worktree descartável** (`scratch`, já no protocolo): as
   mudanças não ficam no repositório. Por isso a execução solta exige pasta git e runner
   com a capacidade `"scratch"`; o projeto que não serve aparece desabilitado com o motivo.
   O job sem pasta (`workdir`) continua válido no protocolo, mas o control plane não o cria
   mais.
4. **Criar projeto com IA é o tipo de proposta `project`.** Recebe runner + pasta (o
   projeto ainda não existe), estuda a pasta num worktree descartável e devolve `analise`,
   `verificacoes` e `projeto`; o resultado preenche o formulário do projeto, e nada é
   gravado até a pessoa salvar. A proposta `pipeline` passa a exigir um projeto existente e
   deixa de propor o projeto; respostas antigas que traziam `projeto` continuam legíveis.
5. **Trocar o runner do projeto** só aceita runner ativo do workspace que ofereça a pasta,
   e fica na auditoria como `project.runner_switched` (`from`, `to`). Tarefas já começadas
   guardam o próprio `runner_id` e não mudam; só o trabalho novo vai para o runner novo. A
   troca de runner de uma tarefa parada (ADR 0032) continua igual.
6. **Runner offline não é erro.** A tarefa, a execução e a proposta são criadas e o job
   fica `queued`; o runner o recebe ao conectar. A tela diz que o trabalho espera o runner.
   A saúde do projeto (`Projects.health/2`) é `:ok`, `:runner_offline`, `:directory_gone`
   (o runner não anuncia mais a pasta) ou `:needs_runner`; só as duas últimas recusam
   trabalho.
7. **Os jobs guardam o projeto** (`jobs.project_id`), para listas, filtros e o uso por
   projeto.

## Migração

- Cada projeto existente recebe o runner ativo do workspace que oferece a pasta, o visto
  por último; sem nenhum, fica sem runner ("precisa de um runner") e não recebe trabalho
  até ter um. Runners revogados são ignorados.
- A migração aborta se houver dois projetos do mesmo workspace com o mesmo
  `github_repo`.
- Os jobs de etapa herdam o projeto da tarefa; os demais, o único projeto da pasta que
  estudaram ou em que rodaram. O resto fica "sem projeto" no uso.

## Consequências

- O runner e o protocolo não mudam; a versão do protocolo segue a mesma. Um runner sem
  `"scratch"` conecta e roda tarefas, mas não recebe execução solta nem proposta.
- O projeto apagado não apaga as tarefas: elas guardam o retrato, o runner e a pasta. Rodar
  de novo uma tarefa cujo projeto sumiu explica que o projeto não existe mais.
- As listas que filtravam por pasta (board, propostas) filtram por projeto.
