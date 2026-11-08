# 04 — Revisão de convenções

Revisei o diff contra `origin/main` (`git diff $(git merge-base HEAD origin/main)`): domínio, web, `mix.exs`, ferramenta de cobertura, testes e specs.

## O que conferi, e o resultado

| Item | Resultado |
|---|---|
| Plano cumprido; critérios de aceite com teste | 1–9 têm teste (`task_page_test.exs`, `jobs_test.exs`, `task_live_stage_panel_test.exs`, `task_live_test.exs` adaptado, `pipeline_components_test.exs`, `task-stage-panel.spec.ts` e os specs adaptados). 10–12 foram rodados na etapa anterior. **13 (documentação) estava sem entrega:** corrigido abaixo. |
| `@moduledoc` | Todo módulo novo tem (`PipelineView`, `StagePanel`, `AttemptComponents`, `DecisionPanel`, as cinco abas, `PipeMaestro.TestCoverage`). |
| `@spec` | Toda função pública nova tem; as cláusulas seguintes de uma função herdam a do primeiro `def`. Dialyzer: 0 erros, sem ignores. |
| LiveView fina | `Show` só tem `mount`, `handle_params`, inscrições, repasse por `send_update/3` e as ações, todas delegadas a `PipeMaestro.Tasks`. `running_job_id/2` e `fingerprint/2` são estado de visão, não regra. |
| `handle_info` | Sem catch-all. Cada mensagem de job tem a cláusula do job seguido e uma explícita para os outros (`{:job_event, _}`, `{:job_delta, _, _}`, `{:job_telemetry, _}`, `{:refresh_spent, _}`); `{:job_updated, _}` é ignorado de propósito, com comentário. |
| Streaming | Assina só o job da etapa aberta e cancela a assinatura ao trocar ou fechar (`Jobs.unsubscribe/1`, com teste). Telemetria mantém o `@live_every`. |
| Petal antes de Tailwind | Cartões, alertas, badges, botões e formulários são Petal. Tailwind cru só no trilho do pipeline (círculo do ícone, linha) e no nó, que não têm primitiva no Petal. `side_panel/1` estendido em vez de criar outro painel. |
| `data-testid` | Todo elemento que testes tocam tem, com a chave da etapa nos por registro (`task-stage-<key>`, `task-stage-attempt-<key>-<n>`…), conforme `e2e/README.md`. Chave de etapa nunca é nula (a changeset deriva do nome). |
| Comentários | Descrevem o código; nenhum narra a mudança. |
| Fronteiras do umbrella | Web usa o domínio e o protocolo como antes; o domínio não importa web; protocolo e runner só ganharam a linha de `mix.exs` da cobertura, sem dependência nova. |
| Exclusões de cobertura | Nenhuma nova: `ignore_modules` dos apps está como estava. |
| Contagens na prosa | Nenhuma nos documentos novos. |
| Payload de `Tasks.notify/1` e tópicos | Inalterados. |

## O que corrigi

1. **Documentação (critério 13):** criei `docs/adr/0046-pagina-da-tarefa-em-fases.md` (pipeline vertical mais painel, etapa na URL, tarefa leve, streaming só do job aberto, componente vertical próprio em vez de `orientation`) e apontei o item "tarefa" da ADR 0040 §6 para ela. O `@moduledoc` de `TaskLive.Show` já estava atualizado.
2. **`test_coverage.exs`:** `value / 1` virou `value * 1.0`, que diz o que faz (o limiar pode ser inteiro).

## Verificação

- `(ulimit -n 256; make ci.quick > /tmp/ciq.log 2>&1; echo $?)` → **0** (Credo sem issues; protocol 113, domínio 592, web 521, runner 273 testes; cobertura acima de 60% em cada app).
- `mix dialyzer` → **0** erros.

## Sem decisão humana pendente

Nada exigiu uma decisão de produto ou de arquitetura, e o protocolo não foi tocado.
