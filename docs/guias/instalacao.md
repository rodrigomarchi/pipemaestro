# Instalação: control plane, runners e o primeiro pipeline

Este guia sobe a plataforma, conecta uma máquina como runner e roda a primeira
tarefa. As decisões por trás estão nos ADRs [0006](../adr/0006-runner-paralelo-e-ambiente-quente.md)
a [0012](../adr/0012-uso-papeis-auditoria-e-segredos.md); o protocolo, em
[`protocolo-runner.md`](../specs/protocolo-runner.md).

## 1. Control plane

### Imagem

```bash
make image        # docker build -t claude-control-plane .
```

A imagem roda `bin/server`: aplica as migrations pendentes e sobe o servidor web na
porta 4000.

### Variáveis

| Variável | Para quê |
|---|---|
| `DATABASE_URL` | Postgres 16: `ecto://usuario:senha@host/banco` |
| `SECRET_KEY_BASE` | assina sessões e cookies (`mix phx.gen.secret`) |
| `SECRETS_KEY` | cifra os segredos dos workspaces. **Trocá-la torna os segredos guardados ilegíveis** |
| `PHX_HOST` | o nome público (ex.: `plataforma.exemplo.com`): entra nas URLs que o runner mostra no login |
| `PORT` | a porta HTTP (padrão 4000) |
| `POOL_SIZE` | conexões com o banco (padrão 10) |

```bash
docker run -d -p 4000:4000 \
  -e DATABASE_URL=ecto://cp:senha@db/claude_control_plane \
  -e SECRET_KEY_BASE=... -e SECRETS_KEY=... \
  -e PHX_HOST=plataforma.exemplo.com \
  claude-control-plane
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
docker exec -it <container> bin/claude_control_plane eval \
  'ClaudeControlPlane.Release.create_operator("ops@empresa.com", "Ops", "uma senha longa")'
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
make runner.install      # gera a release e instala ~/.local/bin/cp-runner
```

A release não leva Phoenix nem Ecto (`_build/prod/rel/claude_control_plane_runner`, ou o
`.tar.gz` ao lado, para copiar para outra máquina com o mesmo sistema). Sem Elixir na
máquina de destino, basta descompactar o tarball e usar `bin/cp-runner`.

**Binário único (sem instalar nada):** `make runner.binary` gera em `burrito_out/` um
executável por plataforma: `cp_runner_macos_arm64`, `cp_runner_macos_x86_64`,
`cp_runner_linux_x86_64` e `cp_runner_linux_arm64`. Cada um leva o Erlang dentro;
basta copiar, renomear para `cp-runner` e usar os mesmos comandos abaixo. Na primeira
execução, ele se descompacta na pasta de dados do usuário.

Para gerar os binários, a máquina do build precisa de:

- Zig 0.16 (`brew install zig@0.16`);
- `xz`;
- o Erlang 28.5 (`asdf install erlang 28.5`): o Burrito publica ERTS por versão do OTP,
  não por patch.

`TARGET=linux_x86_64` gera só um deles.

### Conectar

```bash
cp-runner doctor                                   # confere claude, git, disco...
cp-runner login --url https://plataforma.exemplo.com
cp-runner start --root ~/src                       # oferece os diretórios de ~/src
```

O login mostra um código. Um **admin** do workspace o aprova em
`/runners/activate`. A raiz fica salva, então os próximos `start` não precisam dela.

- **Em segundo plano:** `cp-runner service install` (launchd no macOS, systemd no
  Linux, log em `~/.config/claude-control-plane/runner.log`); `cp-runner service
  uninstall` desfaz.
- **Chave própria:** com `RUNNER_ANTHROPIC_API_KEY` no ambiente do runner, o agente
  usa essa chave em vez do login de quem roda o `claude`. A página do runner mostra
  qual é usada.
- **Capacidade:** `login --capacity N` define quantos jobs rodam ao mesmo tempo.
- **Histórico:** a página do runner lista as últimas execuções que ele terminou, com
  duração, custo, tokens e cache; cada uma abre a auditoria da execução.

## 3. O primeiro pipeline

1. **Pipelines → Criar pipelines padrão.** Os templates (correção de bug,
   funcionalidade, refatoração, revisão, investigação de produção...) já vêm com as
   etapas de leitura restritas.
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

Commit, push e PR ficam, por enquanto, a cargo do prompt de cada etapa (ver o
[roadmap](../plano/03-roadmap-orquestrador.md), Marco 6).
