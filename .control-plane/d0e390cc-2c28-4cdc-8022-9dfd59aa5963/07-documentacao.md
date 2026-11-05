# Documentação e resumo — O projeto como a única escolha de onde o trabalho roda

## Resumo para quem vai revisar

### O que mudou e por quê

Antes, quem disparava trabalho escolhia à mão um runner e uma pasta em cada tela, e o
projeto era só a configuração de um nome de pasta, casada em silêncio. Agora **projeto =
runner + pasta + configuração**, e é a única escolha de nova tarefa, execução solta,
tarefa escrita com IA, propostas e gatilho do GitHub (ADR 0034).

- **`apps/pipe_maestro` (domínio):** migração `projects.runner_id` (com backfill),
  unicidade `(workspace, runner, pasta)`, `github_repo` único por workspace e
  `jobs.project_id`; `Projects` (troca de runner com auditoria, `health/2`,
  `runner_choices/1`); `Tasks` e `Jobs` criam a partir de `project_id`; execução solta
  sempre `scratch`; nova proposta `project` (criar projeto com IA); `Usage`/`Insights`
  agrupam por projeto. Ver `apps/pipe_maestro/priv/repo/migrations/`.
- **`apps/pipe_maestro_web`:** seletor de projeto (`ProjectChoice`) em todas as telas que
  disparam trabalho; projetos com runner, estado e atalhos; board, propostas, decisões,
  PRs e uso mostram/filtram por projeto; webhook usa o runner do projeto (sem runner → 422).
- **`apps/pipe_maestro_protocol`:** sem mudança.
- **`apps/pipe_maestro_runner`:** sem mudança de produção; só o `fake_claude` de teste.
- **`e2e/`:** page objects e specs escolhem o projeto.

### Protocolo e runners antigos

O protocolo **não mudou** (versão igual). Runners atuais seguem compatíveis. Um runner
sem a capacidade `"scratch"` conecta e roda tarefas, mas seus projetos aparecem
desabilitados para execução solta e propostas ("o runner precisa ser atualizado"). O job
sem pasta continua válido no protocolo; o control plane só deixou de criá-lo.

### Riscos e o que olhar com mais atenção

- **Migração de dados** (`20261112090000_add_runner_to_projects.exs`): pasta oferecida por
  vários runners fica com o visto por último; sem nenhum, `runner_id` nulo ("precisa de um
  runner"). Aborta se houver `github_repo` duplicado no workspace. Conferir antes de
  aplicar em produção.
- **Jobs antigos** sem projeto aparecem como "sem projeto" no uso e nos filtros.
- **Troca de runner do projeto** não afeta tarefas já começadas (têm `runner_id` próprio).
- **Fim da execução no `workdir`**: a execução solta agora descarta as mudanças.
- Muitas telas mudam de uma vez; olhar a cobertura por tela e o fluxo de runner offline
  (trabalho espera na fila, sem erro).

### Como verificar

```sh
make ci > /tmp/ci.log 2>&1; echo $?          # 0
make e2e > /tmp/e2e.log 2>&1; echo $?        # 0
make e2e FILE=projects.spec.ts
make e2e.shots                               # claro e escuro
```

Na tela: (1) Projetos → novo, escolher runner e pasta, ou "Analisar com IA" e salvar o
formulário preenchido; (2) trocar o runner de um projeto; (3) Nova tarefa e Execução só
pedem o projeto, e um projeto de runner offline mostra o aviso de espera; (4) board filtra
por projeto; (5) Uso mostra "Por projeto".

Resultados das etapas anteriores: `make ci` saiu 0 (`05-ci.md`); `make e2e` saiu 0 e as
telas foram auditadas em claro e escuro (`06-telas.md`).

### ADRs e documentos

- Nova: `docs/adr/0034-o-projeto-e-a-escolha-de-onde-o-trabalho-roda.md`, listada em
  `docs/README.md`.
- Atualizados: ADR 0008 (marcada como complementada pela 0034), `docs/README.md`,
  `docs/plano/03-roadmap-orquestrador.md`, `docs/specs/maquina-de-estados-tarefa.md` e
  `docs/guias/instalacao.md` (etapa anterior).
- Sem mudança: `docs/specs/protocolo-runner.md`, `docs/guias/ui-petal.md`,
  `docs/guias/phoenix.md`, `e2e/README.md` (nenhuma convenção nova de test id).
