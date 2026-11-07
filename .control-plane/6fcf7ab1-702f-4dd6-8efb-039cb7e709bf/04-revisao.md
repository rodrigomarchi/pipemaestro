# Revisão de convenções

Diff revisado contra `origin/main`.

## Conferido, sem achados
- `@moduledoc` em todos os módulos novos (`Session`, `InstanceLock`, `Outbox.Server`, `Connection.Keeper`) e `@spec` em todas as funções públicas deles.
- LiveView (`task_live/show.ex`): só apresentação; a regra de reenfileirar fica em `Tasks`.
- `data-testid` presentes nos elementos novos, seguindo o padrão `stage-run-*` do `e2e/README.md`; a spec `runner-restart.spec.ts` seleciona só por test id.
- Cores no HTML novo seguem as classes já usadas na tela; sem componente Petal equivalente para esses textos.
- Comentários descrevem o código, não a mudança.
- `handle_info`: o `{:EXIT, _, _}` do `Keeper` descarta apenas links de tarefas já encerradas (comentado), e os exits da conexão são tratados. Sem catch-all que engula mensagem que o código espera.
- Fronteiras do umbrella: o runner só depende de `protocol`; nada de Phoenix/Ecto nele.
- Sem exclusão de cobertura nova e sem contagens na prosa dos docs.
- Critérios de aceite do plano com teste (domínio, runner, canal, LiveView e e2e).

## Resultado
Nenhuma correção necessária. `make ci.quick` passa (exit 0).
