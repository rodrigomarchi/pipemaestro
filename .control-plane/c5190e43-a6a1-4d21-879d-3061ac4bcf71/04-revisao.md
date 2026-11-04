# 04 — Revisão de código: versão do runner no formato AAAA-MM-DD.NN

Revisei `git diff main...HEAD` contra o plano (01) e o contrato dos testes (02). Não há mudanças
fora de commit. Não rodei testes nesta etapa porque o Bash foi negado aqui. Conto com o relato da
etapa 03: `make ci.quick` verde, Dialyzer sem erros e `make e2e.shots` com 14 passed.

**Veredito: nenhum problema grave.** A mudança segue o plano, respeita as fronteiras do umbrella
e cumpre as convenções. Os pontos abaixo são médios ou baixos.

## Conformidade com o AGENTS.md

- **Fronteiras**: o esquema puro e a leitura do git ficam no `protocol`. O runner depende só do
  `protocol`, e o domínio expõe `Runners.outdated?/1,2`. A web chama o domínio e não tem lógica
  própria. Correto.
- **`@spec`/`@moduledoc`**: estão presentes em todos os módulos e funções públicas novos
  (`Version`, `Version.Git`, `PipeMaestro.Version`, `PipeMaestroRunner.Version`,
  `Commands.Version`, `Mix.Tasks.Runner.Version`, `app_version/1`, `runner_version/1`). O
  `Mix.Tasks.Runner.Version.run/1` usa `@impl` sem `@spec`, como as outras tasks do projeto.
- **LiveViews finas**: `runners_live.ex` e `runner_live.ex` só usam o componente.
- **Petal**: o selo usa `<.badge color="warning" variant="soft">`.
- **data-testid**: `app-version`, `runner-version-<nome>`, `runner-outdated-<nome>`,
  `runner-detail-version` e `runner-detail-outdated` estão presentes. As specs e o page object
  selecionam só por test id.
- **Comentários**: descrevem o código, não a mudança.
- **Sem contagens na documentação**: ok.

## Problemas

### Médio

1. **A documentação ainda não está atualizada** (prevista para a etapa de documentação, §4 do
   plano). Itens concretos que estão desatualizados:
   - `docs/guias/instalacao.md:13`: `make image  # docker build -t pipemaestro .`. O
     alvo agora passa `--build-arg CP_VERSION=…`, e quem rodar o `docker build` à mão terá uma
     imagem `dev+unknown` sem nenhum selo.
   - `docs/specs/protocolo-runner.md:28`: o exemplo do Hello ainda mostra
     `"runner_version": "0.1.0"`.
   - Faltam o ADR `0016-esquema-de-versao.md`, a seção de releases no guia (com `runner.rel`, que
     substitui o antigo `runner.release`, e `git fetch --tags` antes de uma release) e o Marco 5
     do roadmap.

   Isso não bloqueia esta etapa, mas a tarefa não está completa sem esses itens.

2. **`make image` engole a falha de `mix runner.version`** (`Makefile:81`). O `$$(… | tail -n 1)`
   mascara o código de saída. Se a compilação falhar, o `docker build` segue com `CP_VERSION` vazio
   ou com uma linha de erro como versão, e o control plane de produção passa a ter versão inválida
   sem que ninguém perceba. O `runner.release` valida o formato com `grep -Eq`; o `image` deveria
   fazer o mesmo (aceitando também `+dev.<sha>` e `dev+<sha>`) ou falhar.

### Baixo

3. **`mix.exs:940`: `Enum.max/1` compara as tags como strings.** Com duas tags de release no HEAD,
   `runner-2026-11-04.99` ganha de `runner-2026-11-04.100`. Além disso, o padrão
   `"runner-" <> _` aceita tags fora do formato, como `runner-2026-11-04.01-rc`. O efeito fica só
   nos metadados de build do Burrito, e o timestamp mantém cada build única, então o impacto é
   cosmético. Mesmo assim, a regra diverge da de `Version.describe/3`. Um comentário que diga que é
   uma aproximação, ou um filtro pelo mesmo regex, resolve.

4. **`--next` aparece no binário** (`commands/version.ex:451`). O plano (§1.3) diz "não exposto no
   binário", mas `pipemaestro --version --next` funciona e lê as tags do diretório atual. É inofensivo,
   mas difere do plano e não aparece no uso. Duas saídas: aceitar e documentar, ou restringir o
   `--next` à Mix task.

5. **`PipeMaestroProtocol.Version.compare/2` levanta `MatchError`** quando um dos lados não
   é uma release pura (`version.ex:250-251`). Hoje nenhum chamador de produção a usa (o
   `outdated?/2` usa `compare_releases/2`), mas é pública e tem `@spec` que aceita qualquer
   `String.t()`. A doc deveria dizer que só aceita releases, ou a função deveria ficar privada ou
   usar uma guarda explícita.

6. **A linha do moduledoc do `Doctor` ficou longa** (`doctor.ex:465`, cerca de 110 colunas, depois
   de "after showing the runner's version:"). O formatter não reflui doc. É cosmético: dá para
   refluir o parágrafo.

7. **A spec e2e depende da linha seguinte** (`runner-connection.spec.ts:899`): espera
   `` `pipemaestro ${version}\nWorkdir:` ``. Se a ordem das linhas do `start` mudar, o teste quebra
   por um motivo alheio à versão. Uma regex com âncora de linha
   (`/^pipemaestro 2026-11-04\.01$/m`) seria mais robusta.

8. **`Version.Git` (I/O de build) vai junto em toda release que carrega o `protocol`.** Isso inclui
   o runtime do control plane e do runner, embora o módulo só seja usado em compilação e pelo
   `--next`. A decisão foi tomada no plano (§2.1) e é aceitável. Fica registrada para o ADR.

## Casos de borda conferidos (ok)

- `CP_VERSION=""` conta como ausente (`git.ex:362`). O e2e usa isso para o runner não herdar a
  versão do servidor.
- A referência `X+dev.sha` usa a base `X`, e `dev+sha` não marca ninguém. Runner dev, legado
  (`0.1.0`) ou `nil` nunca recebe o selo. Os testes do protocolo e do domínio cobrem esses casos.
- `parse_release` rejeita `.00`, datas inválidas e um dígito. `format/2` produz `.100` sem padding
  extra.
- `__mix_recompile__?/0` sem git devolve `dev+unknown` de forma estável e não força recompilação em
  loop.
- O teste não depende do estado git do checkout: `config/test.exs` fixa a versão do control plane.
- Na Docker, `ARG/ENV CP_VERSION` vem antes do `mix compile`, e o default vazio cai em
  `dev+unknown`.
- `runner.release` recusa árvore suja e HEAD já com tag, valida o formato da próxima versão, não
  faz push e, se o build falhar, explica como apagar a tag.

## Testes faltando

- Nenhum teste cobre `Commands.Version.run/1` com argumento inválido (`Output.fail!`). É um caso
  pequeno; incluir se a cobertura do runner estiver perto do limite.
- O `make runner.release` não tem teste automatizado, como o plano já previa. A lógica de
  `next/2` está coberta.
