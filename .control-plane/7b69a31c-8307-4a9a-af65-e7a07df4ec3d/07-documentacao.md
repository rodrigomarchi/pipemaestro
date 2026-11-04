# Documentação e resumo

## Documentos
- **ADR** `docs/adr/0030-screenshots-reais-da-landing.md` (nova, no índice de `docs/README.md`). Nenhuma ADR anterior muda.
- `e2e/README.md`: seção "Diretor da landing" e a exceção na regra de nomes únicos.
- `docs/guias/ui-petal.md`: seção "Screenshots da landing" (`landing_shot/1`).
- `docs/specs/protocolo-runner.md`: sem alteração (o protocolo não mudou).
- Roadmap em `docs/plano/`: sem alteração (a landing não é um marco do plano).

## Resumo para quem revisa

### O que mudou e por quê
A landing só tinha ilustrações; quem chegava não via o produto. Agora ela mostra as telas reais, geradas por um diretor e2e.

- **`pipe_maestro` (domínio) e `pipe_maestro_protocol`:** nada mudou. Sem migração.
- **`pipe_maestro_runner`:** uma correção de defeito, fora do plano. `Changes.snapshot/2` falhava quando um caminho copiado para o worktree (como `deps`) estava no `.gitignore`, e a tarefa ficava sem "arquivos alterados". O diretor encontrou o problema. Teste novo em `changes_test.exs`.
- **`pipe_maestro_web`:**
  - `LandingShots`: dado das seis telas.
  - `landing_shot/1`: janela de navegador com o par de imagens claro/escuro.
  - Landing: hero com o board, tour `#produto`, link "Produto" no menu; "Recursos" enxugado.
  - Imagens versionadas em `priv/static/images/landing/`.
- **`e2e/` e `Makefile`:** diretor (`make landing.shots`, só com `E2E_DIRECTOR=1`), `showcase_claude` (CLI de vitrine separado do `fake_claude`), opções novas em `runnerProcess.ts` (padrões inalterados) e `loadAllShots` no `public-pages.spec.ts`.

### Protocolo
Não mudou. O diretor só troca `CLAUDE_BIN` do runner que ele inicia, e o `stream-json` é o mesmo. Runners antigos não são afetados.

### Riscos e onde olhar
- **Imagens (revisar no PR):** nenhuma pode ter "e2e", "fake", UUID nem hostname real. Cada uma deve ter menos de 600 KB (`LandingShotsTest` confere tamanho e dimensões).
- **`make landing.shots` apaga o banco e2e** do worktree. Os bytes das imagens variam entre execuções (horários relativos, fragmento do id no branch); os nomes e as dimensões não.
- **Foto `task` sem `task-files`:** essa lista mostra caminhos com o UUID da tarefa, e o critério proíbe UUID visível.
- **`tour-board` é `eager`:** usa o mesmo arquivo do hero, que o teste trata como eager. Sem custo extra de rede.
- **Correção no runner:** é o único código de runtime fora da web; confira `changes.ex`.
- **`make ci` completo (com Dialyzer):** a etapa 5 registra o resultado; rode de novo se houver dúvida.

### Como verificar
```bash
make ci > /tmp/ci.log 2>&1; echo $?                      # 0
make e2e.typecheck
make e2e                                                 # verde
make e2e.shots FILE=tests/public-pages.spec.ts           # hero e tour, claro/escuro, 1440 e 390 px
make landing.shots && git status                         # regrava os mesmos arquivos (apaga o banco e2e)
make help | grep landing.shots
```
Na tela: abrir `/`, ver o hero com o board e o tour `#produto`; alternar o tema e conferir que as imagens trocam; em 390 px, sem rolagem horizontal.
