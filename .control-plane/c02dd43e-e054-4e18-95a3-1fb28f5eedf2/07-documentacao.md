# Documentação e resumo

## Documentos

- **ADR novo:** [`docs/adr/0053-qualidade-das-entregas.md`](../../docs/adr/0053-qualidade-das-entregas.md),
  agora no índice `docs/README.md`. Nenhuma ADR anterior muda: ela só acrescenta a medição de
  qualidade às ADRs 0012, 0024 e 0045.
- **Specs:**
  - `docs/specs/integracoes.md`: o `PrOutcome` no modelo de dados, as datas do evento
    `:pr_closed`, o PR fechado sem merge e o review repetido, e a seção 8, "Desfecho do PR",
    com a callback `pr_commits/3` e os endpoints.
  - `docs/specs/maquina-de-estados-tarefa.md`: `Decision.origin` e o desfecho do PR.
- **Roadmap:** `docs/plano/01-visao-arquitetura.md` §9 aponta a aba Qualidade e deixa em
  aberto a taxa de revert e o tamanho do diff.
- **`AGENTS.md`:** as linhas de `Usage` e `Integrations` descrevem a parte nova.
- Não mudam: `protocolo-runner.md` (o protocolo não mudou), `docs/guias/*` e `e2e/README.md`,
  porque a tela usa os padrões que já existem.

## Resumo para quem vai revisar

### O que mudou e por quê

O Uso mostrava quanto o trabalho dos agentes custou, e agora mostra também se ele foi
aceito. É a métrica de qualidade prevista no plano da Fase 3.

**`apps/pipe_maestro` (domínio)**
- **Desfecho do PR por tarefa:** a tabela `integration_pr_outcomes` guarda, por tarefa
  entregue em PR, quando ficou pronta (`ready_at`, só na primeira vez), se foi integrada,
  fechada ou segue aberta, as rodadas de review e os commits do pipeline e de pessoas.
  - A classificação (aceito sem alteração, com alteração, fechado, em aberto) é calculada
    na leitura.
  - Quem escreve é `Integrations.PrOutcomes`, e o `Usage` só lê.
- **Commit humano por SHA:** a callback `Provider.pr_commits/3` (GitHub e Forgejo) lista os
  commits do PR. Um commit que o pipeline não empurrou, fora os de merge, conta como de uma
  pessoa. O autor do commit não serve, porque o runner commita com a identidade da máquina
  da pessoa.
- **Origem das correções:** `Decision.origin` (pessoa, review ou merge automático) separa o
  retrabalho por origem.
- **Webhooks e reconciliação:**
  - o merge e o PR fechado sem integrar gravam o desfecho (antes o fechado era ignorado);
  - o mesmo review repetido não abre uma segunda correção;
  - o `Reconciler` pega o merge que o webhook perdeu.
- **Métricas:** `Usage.quality/3` dá as taxas por pipeline e por semana, a mediana até o
  merge, o retrabalho por etapa e as etapas que mais pausam.

**`apps/pipe_maestro_web`**
- A aba **Qualidade** (`?aba=qualidade`) no Uso e o filtro de projeto na barra do topo, que
  vale para todas as abas. O LiveView só delega para `Usage`.

**`apps/pipe_maestro_protocol` e `apps/pipe_maestro_runner`:** não mudam.

### Protocolo e runners antigos

O protocolo e os Channels não mudam e a versão não sobe. O `head_sha` continua vindo do
`delivery["commit"]` que o runner já envia, então runners antigos seguem compatíveis.

### Riscos e o que olhar com mais atenção

- **Critério de commit humano** (ADR 0053):
  - um commit de pessoa que o runner incorpora durante uma etapa conta como do pipeline;
  - um force-push mantém os SHAs reescritos já contados;
  - o GitHub lista no máximo 250 commits por PR.
- **Modo `runner`:** conexões com `api_mode` `runner` não deixam a plataforma ler commits.
  Nelas só os reviews contam como alteração, e a aba avisa quantos PRs ficaram sem essa
  leitura.
- **Custo de API:** cada PR aberto custa uma leitura de commits por mudança da tarefa e uma
  consulta por passagem do `Reconciler` (a cada 5 minutos), até o merge ou o fechamento.
- **Migrações:** são aditivas (tabela nova e coluna `decisions.origin`). A segunda preenche
  as correções antigas como `person`, ou `auto_merge` onde a decisão veio do "merge
  automático". Tarefas anteriores não ganham desfecho, e os reviews antigos não se distinguem
  de correções pedidas por uma pessoa.
- **Chave do review no Forgejo:** o webhook não traz o id do review, então a chave é o id da
  entrega original.
- **Flake no e2e:** `runner-telemetry.spec.ts` falhou uma vez por timeout no backoffice, fora
  da tela alterada. Passou isolado e na rodada seguinte da suíte inteira.

### Como verificar

```bash
make ci                                              # compile, format, credo, testes com cobertura e dialyzer
make e2e FILE=tests/usage-quality.spec.ts            # o fluxo da aba Qualidade
make e2e.shots FILE=tests/usage-quality.spec.ts      # screenshots claro e escuro
```

Passos manuais na tela:
1. Uso e limites → aba **Qualidade**. Sem PRs no período, aparece o estado vazio.
2. Com uma tarefa entregue em PR de um repositório vinculado, faça um commit no branch
   do PR e integre o PR. O cartão "Aceitos com alteração" passa a contar.
3. Um review pedindo mudanças que vira "Correção N" também conta como alteração, e a
   correção aparece em "Correção por review" na tabela de retrabalho.
4. Troque pipeline, projeto e período na barra do topo: todos os números da aba mudam.

### Estado dos gates

`make ci` (com Dialyzer) e `make e2e` (suíte inteira) estão verdes na árvore do código.
Esta etapa só alterou documentação.
