# Deploy em produção (pipemaestro.app)

O control plane roda no **Sun**, o servidor de produção. Ele é provisionado pelo Ansible do
repositório `retro_hex_chat_infra`, do mesmo jeito que os outros apps Elixir de lá:

- **Postgres:** usuário e banco `pipe_maestro`.
- **Clone:** `~/pipemaestro`, buscado do Forgejo com o token de leitura do servidor.
- **DeployEx:** o app `pipe_maestro`, na porta 4008.
- **HAProxy:** 14008.
- **nginx e certificado:** `pipemaestro.app`. O `www` responde 301. O `server` precisa
  de `client_max_body_size 12m;`, porque os runners sobem os arquivos dos jobs (até
  10 MiB cada, [ADR 0042](../adr/0042-arquivos-gerados-pela-etapa.md)). Com o padrão de
  1 MB, os maiores voltam com 413 e aparecem na tarefa como "não chegaram". Com 12m
  há folga sobre os 10 MiB (10.485.760 bytes). Uma recusa por cota do workspace
  ([ADR 0053](../adr/0053-retencao-por-workspace.md)) **não** é um 413 do nginx: ela vem
  do app, com o corpo JSON `{"error": "quota_exceeded", "quota_bytes"}`, e aparece na
  tarefa como "arquivos recusados".

Os segredos ficam no vault da infra e entram no ambiente do app pelo DeployEx:

| Variável | Vault |
|---|---|
| `DATABASE_URL` | `vault_pipe_maestro_db_password` |
| `SECRET_KEY_BASE` | `vault_pipe_maestro_secret_key_base` |
| `SECRETS_KEY` | `vault_pipe_maestro_secrets_key` |

O `SECRETS_KEY` cifra os segredos dos workspaces. Se ele mudar, os segredos que já estão no
banco ficam ilegíveis.

## DNS

Os registros A de `pipemaestro.app` e `www.pipemaestro.app` apontam para o IP do Sun, que está
em `inventory/hosts.yml` da infra. O certificado só sai depois que o DNS responder esse IP. Até
lá, o vhost serve em HTTP.

## Publicar

A `main` só muda por pull request: o Forgejo recusa push direto nela, inclusive de admins.
Cada merge publica sozinho
([ADR 0026](../adr/0026-deploy-pelo-forgejo-e-main-protegida.md)):

1. o merge na `main` dispara `.forgejo/workflows/deploy.yml`;
2. o runner do repositório, no Moon, roda `scripts/deploy_sun.sh main`;
3. o deploy aparece em Forgejo → pipemaestro → **Ações**, com o log inteiro e o
   `RELEASE=...` no fim.

Para refazer o deploy da `main` sem um merge novo, use **Ações → deploy → Executar
workflow** (`workflow_dispatch`).

O deploy manual continua valendo, para uma emergência ou outra ref:

```bash
cp .env.example .env    # uma vez: DEPLOY_USER e SUN_IP
make deploy             # make ci, build no Sun e espera o rollout
make deploy.skip-ci     # o mesmo sem o make ci; REF=<branch|tag> escolhe outra ref
```

O `scripts/deploy_sun.sh` faz quatro coisas:

1. pede ao Sun `~/bin/pipemaestro-deploy deploy <ref>`. Esse script, instalado pela role
   `deploy_access` da infra, busca o clone e roda o `scripts/deploy.sh` daquela ref, um
   deploy por vez. A chave SSH do runner do Forgejo está presa a ele no
   `authorized_keys` e não abre shell;
2. o `scripts/deploy.sh`, no Sun:
   - alinha o clone com `origin/<ref>`;
   - compila a release `pipe_maestro` com a versão `<mix>-<sha>`;
   - entrega o tarball ao DeployEx, que roda `PipeMaestro.Release.migrate` antes de subir a
     versão nova;
3. ainda no Sun, se a versão do runner do commit mudou, o mesmo script gera os
   binários do runner na imagem `docker/runner-binary` e os publica em
   `/var/www/pipemaestro/downloads/runner/`, com um `VERSION` que nomeia a versão deles.
   A versão do runner é a do último commit que mudou o runner
   ([ADR 0035](../adr/0035-versao-propria-do-runner.md)): quando o `VERSION` publicado é
   igual a ela, os binários não são gerados de novo, e os runners não precisam se
   atualizar.
   O nginx serve esses binários em `/downloads/runner/`, e a tela de runners tem os
   links. O primeiro deploy constrói a imagem e o cache, e é mais lento. Os runners se
   atualizam a partir desse diretório
   ([ADR 0025](../adr/0025-atualizacao-automatica-do-runner.md)), só se ele estiver na
   mesma origem da plataforma (o mesmo host, com https): um `RUNNER_DOWNLOADS_URL` em
   outro host desliga a atualização automática. Recusado pela versão, cada runner
   termina os jobs que roda (até 30 min), se atualiza e volta sozinho, no terminal, com
   `nohup` ou como serviço; o que passar do prazo roda de novo sem gastar tentativa
   ([ADR 0043](../adr/0043-runner-resiliente-a-reinicios.md)). **Nota de transição:**
   um runner anterior à ADR 0043 se atualiza pelo código antigo uma última vez; se
   roda sem terminal e fora de `pipemaestro service install`, ele para nesse salto e
   precisa ser iniciado de novo à mão;
4. consulta `https://pipemaestro.app/version` até a release nova responder. Desiste depois de
   `ROLLOUT_TIMEOUT_S`, que por padrão é 300 segundos.

## Primeira vez

O primeiro operador do backoffice é criado dentro do nó que está rodando, porque só ele tem
o ambiente do DeployEx (`DATABASE_URL` e os segredos): um `bin/pipe_maestro eval` aberto por
SSH falha ao configurar o banco. Por SSH no Sun, um `rpc` alcança esse nó, usando o nome e o
cookie com que o DeployEx o iniciou:

```bash
dir=$(ls -d /var/lib/deployex/service/pipe_maestro/*/current | head -1)
node=$(basename "$(dirname "$dir")")      # pipe_maestro-<instância>
cookie=$(sudo ps -eo args | grep -- "-sname $node" | grep -o -- '-setcookie [^ ]*' | head -1 | cut -d' ' -f2)
sudo -u deployex env RELEASE_COOKIE="$cookie" RELEASE_NODE="$node" RELEASE_DISTRIBUTION=sname \
  HOME=/var/lib/deployex "$dir/bin/pipe_maestro" rpc \
  'PipeMaestro.Release.create_operator("voce@exemplo.com", "Nome", "uma senha longa") |> IO.inspect()'
```

Não imprima o cookie: ele é o mesmo de todos os apps do DeployEx. O `ps` precisa de `sudo`: o processo é do usuário `deployex` e o `/proc` do Sun esconde os processos de outros usuários. Sem o `sudo`, o cookie sai vazio e o `rpc` falha com `:noconnection`.

Os workspaces e os usuários saem do backoffice. Cada runner se conecta com:

```bash
pipemaestro login          # sem --url, usa https://pipemaestro.app
pipemaestro start --root ~/src
```

## Operar

Na pasta da infra:

- `make logs-pipemaestro` mostra o log do app;
- `make check-urls` testa o HTTPS de todos os domínios;
- o dashboard do DeployEx mostra a versão no ar, o histórico de deploys e permite o rollback.
