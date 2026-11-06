# Instalação: control plane, runners e o primeiro pipeline

Este guia sobe a plataforma, conecta uma máquina como runner e roda a primeira
tarefa. As decisões por trás estão nos ADRs [0006](../adr/0006-runner-paralelo-e-ambiente-quente.md)
a [0012](../adr/0012-uso-papeis-auditoria-e-segredos.md); o protocolo, em
[`protocolo-runner.md`](../specs/protocolo-runner.md).

## 1. Control plane

### Imagem

```bash
make image        # docker build --build-arg CP_VERSION=<versão> -t pipemaestro .
```

A imagem roda `bin/server`: aplica as migrations pendentes e sobe o servidor web na
porta 4000.

A imagem não leva o `.git`, então a versão entra pelo `--build-arg CP_VERSION`, que o
`make image` calcula (`make runner.version`). Num `docker build` feito à mão sem esse
argumento, o control plane fica `dev+unknown` e não marca nenhum runner como
desatualizado (seção 4).

### Variáveis

| Variável | Para quê |
|---|---|
| `DATABASE_URL` | Postgres 16: `ecto://usuario:senha@host/banco` |
| `SECRET_KEY_BASE` | assina sessões e cookies (`mix phx.gen.secret`) |
| `SECRETS_KEY` | cifra os segredos dos workspaces e as credenciais das integrações. **Trocá-la torna os segredos e as credenciais guardados ilegíveis** |
| `PHX_HOST` | o nome público (ex.: `plataforma.exemplo.com`): entra nas URLs que o runner mostra no login, nos webhooks e nos links que a plataforma escreve nas issues |
| `GITHUB_APP_ID`, `GITHUB_APP_SLUG`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_CLIENT_SECRET`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_APP_WEBHOOK_SECRET` | opcionais: o GitHub App da plataforma ([`github-app.md`](github-app.md)). Sem elas, só o Forgejo se conecta ([`integracoes-forgejo.md`](integracoes-forgejo.md)) |
| `INTEGRATIONS_ALLOW_PRIVATE_HOSTS` | `true` para conectar um Forgejo numa rede interna (plataforma self-hosted ao lado dele) |
| `PORT` | a porta HTTP (padrão 4000) |
| `POOL_SIZE` | conexões com o banco (padrão 10) |

```bash
docker run -d -p 4000:4000 \
  -e DATABASE_URL=ecto://cp:senha@db/pipe_maestro \
  -e SECRET_KEY_BASE=... -e SECRETS_KEY=... \
  -e PHX_HOST=plataforma.exemplo.com \
  pipemaestro
```

### TLS e WebSocket

Ponha um proxy com TLS na frente (Caddy, nginx, um balanceador). Ele precisa repassar
WebSockets em duas rotas: `/live`, das telas, e `/runner/socket`, por onde os runners
ficam conectados. No nginx:

```nginx
location / {
  proxy_pass http://127.0.0.1:4000;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_read_timeout 1h;
}
```

O `proxy_read_timeout` longo evita que o proxy derrube runners ociosos. O runner
reconecta sozinho, mas cada queda é uma reconexão à toa.

### Primeiro operador, workspace e pessoas

```bash
docker exec -it <container> bin/pipe_maestro eval \
  'PipeMaestro.Release.create_operator("ops@empresa.com", "Ops", "uma senha longa")'
```

Com esse operador, entre em `/backoffice`:

1. crie o workspace;
2. adicione as pessoas. A primeira de cada workspace vira **admin**; as outras entram
   como **membro**, e o papel muda na mesma tela.

Admins gerenciam pipelines, projetos, runners e segredos; todos rodam e decidem
tarefas.

## 2. Runner (cada máquina de desenvolvimento)

O runner precisa do `claude` instalado e logado (ou de uma chave, abaixo), de `git` e
das ferramentas dos projetos (Elixir, Node...). Ele roda os agentes na própria máquina,
sem container.

### Instalar

Numa máquina com Elixir, a partir deste repositório:

```bash
make runner.install      # gera a release (make runner.rel) e instala ~/.local/bin/pipemaestro
```

A release não leva Phoenix nem Ecto (`_build/prod/rel/pipe_maestro_runner`, ou o
`.tar.gz` ao lado, para copiar para outra máquina com o mesmo sistema). Sem Elixir na
máquina de destino, basta descompactar o tarball e usar `bin/pipemaestro`.

**Binário único (sem instalar nada):** `make runner.binary` gera em `burrito_out/` um
executável por plataforma: `pipemaestro_macos_arm64`, `pipemaestro_macos_x86_64`,
`pipemaestro_linux_x86_64` e `pipemaestro_linux_arm64`. Cada um leva o Erlang dentro;
basta copiar, renomear para `pipemaestro` e usar os mesmos comandos abaixo. Na primeira
execução, ele se descompacta na pasta de dados do usuário.

Para gerar os binários, a máquina precisa só de Docker: o build roda na imagem
`docker/runner-binary`, a mesma que o deploy usa no servidor (ver a
[ADR 0020](../adr/0020-binarios-do-runner-no-deploy.md)). `TARGET=linux_x86_64` gera só
um deles.

Em produção não é preciso gerar nada: cada deploy publica os binários, e a tela
**Executores** tem o link de cada plataforma, da mesma versão do control plane.

### Conectar

```bash
pipemaestro doctor                                   # confere claude, git, disco...
pipemaestro login                                    # https://pipemaestro.app; outra: --url <plataforma>
pipemaestro start --root ~/src                       # oferece os diretórios de ~/src
```

O login mostra um código. Um **admin** do workspace o aprova em
`/runners/activate`. A raiz fica salva, então os próximos `start` não precisam dela.

- **Em segundo plano:** `pipemaestro service install` (launchd no macOS, systemd no
  Linux, log em `~/.config/pipemaestro/runner.log`); `pipemaestro service
  uninstall` desfaz.
- **Chave própria:** com `RUNNER_ANTHROPIC_API_KEY` no ambiente do runner, o agente
  usa essa chave em vez do login de quem roda o `claude`. A página do runner mostra
  qual é usada.
- **Capacidade:** `login --capacity N` define quantos jobs rodam ao mesmo tempo.
- **Histórico:** a página do runner lista as últimas execuções que ele terminou, com
  duração, custo, tokens e cache; cada uma abre a auditoria da execução.

## 3. O primeiro pipeline

**O atalho: Pipelines → Gerar com IA.** Escolha um runner online, um dos diretórios git
dele, e conte o que o pipeline deve fazer. O agente estuda o projeto num worktree
descartável (nada muda no seu código) e roda os comandos que encontrar. Depois propõe a
configuração do projeto e um pipeline. Revise e salve o projeto, depois o pipeline, que
abre preenchido. Se precisar, gere de novo com um comentário
([ADR 0021](../adr/0021-propostas-de-pipeline-pelo-agente.md)). Isso exige um runner
atualizado: os antigos aparecem como "atualize o runner".

Ou, à mão:

1. **Pipelines → Criar pipelines padrão.** Os templates (correção de bug,
   funcionalidade, refatoração, revisão, investigação de produção...) já vêm prontos.
   As etapas rodam com todas as permissões e seguem sozinhas; a tarefa só para quando
   precisa de ajuda ([ADR 0018](../adr/0018-etapas-autonomas.md)).
2. **Projetos → Novo projeto**, para cada diretório que vai receber tarefas:
   - o comando de setup, que roda uma vez por worktree (`mix deps.get && mix
     compile`);
   - os de teste e de lint;
   - o que copiar do checkout (`deps`, `_build`; em branco, o runner detecta).

   Os prompts usam `{{projeto.teste}}`, e os gates das etapas também.
3. **Tarefas → Nova tarefa:** escolha o pipeline, um runner online e o diretório, e
   descreva o pedido. Cada tarefa roda num `git worktree` próprio; o seu checkout não é
   tocado.
4. Acompanhe na tarefa:
   - o texto do agente ao vivo;
   - os artefatos de cada etapa e o diff do que ela mudou;
   - os gates.

   Quando ela pedir uma decisão, ela aparece em **Decisões** (e como notificação).
5. **Segredos** (admins) guarda tokens que os agentes usam, por exemplo de um servidor
   MCP do pipeline. No MCP, refira-se a eles como `${NOME}`.

### Pedir ao agente

O mesmo padrão (você pede, o agente estuda o projeto num worktree descartável e propõe,
e você revisa) aparece em outros pontos. Tudo fica em **Propostas**
([ADR 0022](../adr/0022-propostas-do-agente-como-mecanismo-geral.md)):

- **Tarefas → Escrever com IA:** conte a ideia (e, se quiser, a issue). O agente escreve
  título, contexto, arquivos envolvidos, critérios de aceite e o pipeline que serve, e
  diz se está clara o bastante. "Revisar e criar a tarefa" abre o formulário preenchido.
- **Decisões, ou o painel da tarefa → Sugerir com IA:** numa tarefa parada, o agente lê
  a pergunta, as tentativas, os gates e o diff, e recomenda tentar de novo, avançar ou
  cancelar, com as instruções prontas para você ajustar e aplicar.
- **Pipelines → Melhorar com IA** (em cada pipeline): o agente lê como as últimas
  tarefas correram (falhas, gates, decisões, custo por etapa) e propõe o pipeline
  revisado e as notas do projeto. Salvar o pipeline gera a versão seguinte.
- **Projetos → gatilho do GitHub → "O agente escreve a tarefa antes":** uma issue com a
  label vira uma proposta de tarefa para alguém revisar, em vez de começar direto.

Commit, push e PR ficam, por enquanto, a cargo do prompt de cada etapa (ver o
[roadmap](../plano/03-roadmap-orquestrador.md), Marco 6).

## 4. Versões e releases

A regra está no [ADR 0016](../adr/0016-esquema-de-versao.md).

### A versão

- Uma release é `AAAA-MM-DD.NN`: a data local de quem fez a release e o número dela no
  dia (`2026-11-04.01`, `2026-11-04.02`, `2026-11-05.01`). Ela é a tag anotada
  `runner-AAAA-MM-DD.NN`.
- Um build de um commit sem tag é `<última release>+dev.<commit>`, ou `dev+<commit>` se
  ainda não houver release. Sem git, é `dev+unknown`.
- Runner e control plane usam a mesma série.
- `make runner.version` imprime a versão do checkout. `pipemaestro --version` (ou
  `pipemaestro version`) imprime a do runner instalado.
- O runner também mostra a versão na primeira linha do `start`, no `status` e no
  `doctor`.
- O control plane mostra a dele no rodapé da barra lateral e no pé das páginas
  públicas.

### Gerar uma release

```bash
git fetch --tags        # para não repetir um número já publicado
make runner.release     # tag runner-AAAA-MM-DD.NN + binário em burrito_out/ ([TARGET=...])
git push origin runner-AAAA-MM-DD.NN
```

O `make runner.release`:

- recusa uma árvore com mudanças e um commit que já seja release;
- cria a tag e roda `make runner.binary`;
- não publica nada. Se o build falhar, a tag continua local, e a mensagem diz como
  apagá-la (`git tag -d runner-…`).

Para o control plane da mesma release, rode `make image` no mesmo commit.

O alvo que só gera a release Mix (sem tag) é `make runner.rel`.

### Runner desatualizado

**Só conecta o runner que está na versão da plataforma**
([ADR 0023](../adr/0023-runner-na-versao-da-plataforma.md)). Um runner em outra versão é
recusado no `login` e no `start`.

O binário único se atualiza sozinho
([ADR 0025](../adr/0025-atualizacao-automatica-do-runner.md)). No terminal, ele pergunta:

```
Este runner está na versão dev+abc1234 e a plataforma está na dev+def5678.
Baixar e instalar a versão dev+def5678 agora? [S/n]
```

Com "sim" (ou Enter), ele baixa o binário da plataforma, confere o SHA-256 contra o
`SHA256SUMS`, troca o executável e roda o mesmo comando de novo. Com "não", mostra as
duas versões e o link para baixar a atual, e sai.

- **`--auto-update`** (no `start` ou no `login`) atualiza sem perguntar. Sem terminal e
  sem essa opção, o runner não pergunta: mostra a mensagem e sai.
- **Serviço:** `pipemaestro service install` já grava `start --auto-update`. O serviço
  sai depois de trocar o binário, e o launchd ou o systemd o sobe na versão nova. Quem
  instalou o serviço antes desta versão precisa rodar `pipemaestro service install` de
  novo.
- **Sem permissão de escrita** no diretório do binário: o runner mostra o caminho e os
  comandos para atualizar à mão (`curl`, `shasum -a 256 -c`, `chmod`, `mv`).
- Runners anteriores a esta versão não sabem se atualizar: a primeira atualização
  automática acontece no deploy seguinte ao que publicar esta versão. Até lá, baixe o
  binário pela tela **Executores** (ou pelo link da mensagem).
- **Em dev** (`make runner.*`), o runner não se atualiza: atualize o código e reinicie o
  runner junto com o servidor depois de um commit.

A lista de runners e a página de cada runner mostram a versão. Um runner numa release
anterior à do control plane recebe o selo **desatualizado**. Um control plane num
commit depois de uma release compara com essa release.

Não recebem o selo:

- runners de dev (`+dev`, `dev+`);
- runners de formato antigo (`0.1.0`);
- runners de qualquer versão, quando o control plane não tem release nenhuma.
