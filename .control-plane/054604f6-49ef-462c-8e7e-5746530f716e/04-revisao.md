# Revisão de convenções

Diff revisado contra `origin/main`: plano cumprido, e todos os critérios de aceite têm teste (ExUnit e e2e).

## Verificado sem achados
- `@moduledoc` e `@spec` em `BrandComponents`; `Layouts.brand/1` mantém o `@spec`.
- Nenhuma regra de negócio nas LiveViews; o domínio não mudou.
- Sem `handle_info` catch-all, sem dependência cruzando fronteira do umbrella e sem exclusão de cobertura.
- Comentários e docs descrevem o código, sem contagens na prosa.

## Corrigido
- **A landing tem duas marcas** (nav e rodapé) com o mesmo `data-testid="brand"`, e a spec e2e usava `.first()`, que o `e2e/README.md` proíbe. `Layouts.brand/1` ganhou o attr `testid` (padrão `"brand"`; o símbolo leva `<testid>-mark`). O rodapé usa `footer-brand`, e a spec seleciona só por test id.
- O cabeçalho `@flow C` da spec estava `[todo]`, embora o teste já exista: agora é `[done]`.
- Teste novo para o attr `testid`.

`make ci.quick` passou (exit 0).
