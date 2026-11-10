# 0016 — Esquema de versão do runner e do control plane

- **Status:** aceita; ajustada pela [ADR 0035](0035-versao-propria-do-runner.md): o runner tem a própria versão, no mesmo esquema
- **Data:** 04/11/2026
- **Roadmap:** Marco 5 de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)

## Contexto

O runner se anunciava com o `vsn` da app (`0.1.0`), que nunca mudava. Na lista de
runners, não dava para saber quem rodava um build antigo. O binário Burrito usava
`0.1.0+<commit>`, que não aparecia em lugar nenhum. O control plane não mostrava a
própria versão. Faltava um número que um operador lesse e comparasse.

## Decisões

1. **Formato `AAAA-MM-DD.NN`.**
   - A data é a local da máquina que faz a release. `NN` é sequencial no dia, com dois
     dígitos, e recomeça em `01` a cada dia. Acima de `99` cresce sem padding extra
     (`100`).
   - A comparação é pela data e depois por `NN`, como número (`.10` > `.09`).
   - Runner e control plane saem do mesmo umbrella e usam uma única série de versões.
2. **A tag git é a fonte de verdade.**
   - Uma release é uma tag anotada `runner-AAAA-MM-DD.NN`. Tags fora desse formato (com
     data inválida, `NN` de um dígito ou `00`, ou sufixo) são ignoradas em todo cálculo.
   - Com a tag no HEAD, a versão é a da tag (havendo mais de uma, a maior).
   - Sem tag no HEAD, a versão é `<maior tag alcançável do HEAD>+dev.<commit curto>`.
     Sem tag alcançável, é `dev+<commit curto>`. Sem git ou sem repositório, é
     `dev+unknown`.
3. **Embutida na compilação.**
   - `PipeMaestroRunner.Version` e `PipeMaestro.Version` guardam a versão
     num atributo de módulo. `__mix_recompile__?/0` os recompila quando o valor
     calculado mudaria, então um commit ou uma tag novos aparecem sem `--force`.
   - A variável `CP_VERSION`, quando definida e não vazia na compilação, é usada como
     está. O e2e fixa versões assim, e a imagem Docker também, porque não tem `.git`.
   - O `make image` calcula `CP_VERSION` e `RUNNER_VERSION` antes do `docker build`. Ele
     para se o cálculo falhar ou se uma delas sair do esquema, e só então as passa como
     `--build-arg`. O `Dockerfile` exige as duas. A exceção é um build local
     explícito com `--build-arg ALLOW_UNVERSIONED=1`, em que as que faltam ficam `dev+unknown`.
   - O control plane aceita também uma versão configurada
     (`config :pipe_maestro, PipeMaestro.Version, version: …`), que os
     testes usam para não depender do git do checkout.
4. **O esquema mora no `protocol`.**
   - `PipeMaestroProtocol.Version` tem as funções puras: interpretar, comparar,
     calcular a próxima e decidir se um runner está desatualizado.
   - `PipeMaestroProtocol.Version.Git` lê o git, sempre com diretório explícito.
   - Os dois lados calculam a versão do mesmo jeito, e o control plane interpreta a que
     o runner manda. O `protocol` é a única app que os dois compartilham.
   - O `Version.Git` vai junto nas releases, embora só sirva na compilação e no
     `--next`. É um módulo pequeno e sem dependências.
5. **Sem mudança no protocolo.** O `runner_version` do `Hello` continua uma string de 1
   a 120 bytes, e o `protocol_version` não muda. Runners antigos (`0.1.0`) continuam
   aceitos e aparecem como estão.
6. **Selo "desatualizado".**
   - A lista de runners e a página do runner marcam o runner (badge Petal `warning`)
     quando valem as três condições:
     - a versão dele é uma release pura;
     - a do control plane tem uma base de release (pura, ou `X+dev.<commit>` com base
       `X`);
     - a do runner é anterior a essa base.
   - Runners de dev, de formato desconhecido ou sem versão não são marcados. Um control
     plane `dev+<commit>` não marca ninguém.
   - A regra fica em `Runners.outdated?/1,2`, que delega ao `protocol`.
7. **Onde a versão aparece.**
   - No runner: `pipemaestro --version` e `pipemaestro version` (só a versão). Também na
     primeira linha do `start`, no `status` e no primeiro item do `doctor`.
   - No control plane: no rodapé da sidebar dos layouts do workspace e do backoffice, e
     no pé das páginas públicas.
8. **`make runner.release`.**
   - Recusa uma árvore com mudanças e um HEAD que já tenha tag `runner-*`.
   - Calcula a próxima versão com a data local (`mix runner.version --next`) e cria a
     tag anotada. Depois gera o binário com `make runner.binary`.
   - Não faz push: no fim, imprime o comando.
   - O alvo que gerava a release Mix passou a se chamar `make runner.rel`, e o
     `runner.install` depende dele.
9. **A versão do Burrito continua semver.** Ela é
   `0.1.0+<release ou commit>.<instante UTC do build>`: cada build tem uma versão
   própria, e o binário se descompacta uma vez por versão. Nenhuma tela mostra essa
   string.

## Consequências

- **Data local e tags locais.** A próxima versão vem das tags que a máquina conhece.
  Sem `git fetch --tags` antes, dá para recriar uma tag já publicada; nesse caso, o
  push dela falha. O guia pede o fetch antes da release.
- **A imagem só sai com versão válida.**
  - O `Makefile` define as expressões do esquema uma vez, espelhando as de
    `PipeMaestroProtocol.Version`. O `runner.release` exige uma release pura. O `image`
    aceita as três formas de um build (`AAAA-MM-DD.NN`, `AAAA-MM-DD.NN+dev.<commit>` e
    `dev+<commit>`) e recusa o resto: vazia, linha de erro e `dev+unknown`.
  - `make cp.version` e `make runner.version` falham quando o `mix` falha. Com a
    compilação quebrada, o `image` para antes do `docker build` e diz qual versão
    falhou e o que veio.
  - Um `docker build` à mão sem as duas versões para antes de compilar, apontando o
    `make image`. Com `--build-arg ALLOW_UNVERSIONED=1`, a imagem sai `dev+unknown` e
    não marca nenhum runner como desatualizado. Serve só a builds locais.
- **Cada `mix compile` roda git** para decidir se recompila os dois módulos de versão.
  O custo é pequeno. Sem git, o valor é estável (`dev+unknown`) e não força
  recompilação.
- **Versão visível sem login.** As páginas públicas mostram a versão do control plane,
  que num build de dev inclui o commit curto.
- **`--next` também existe no binário** (`pipemaestro version --next`). Ele lê as tags do
  diretório atual e não muda nada.
- **Discos com binários antigos.** Como cada build do Burrito tem versão própria, cada
  um deixa um payload descompactado na pasta de dados do usuário.
