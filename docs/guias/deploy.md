# Deploy em produção (pipemaestro.app)

O control plane roda no **Sun**, o servidor de produção. Ele é provisionado pelo Ansible do
repositório `retro_hex_chat_infra`, do mesmo jeito que os outros apps Elixir de lá:

- **Postgres:** usuário e banco `pipe_maestro`.
- **Clone:** `~/pipemaestro`, buscado do Forgejo com o token de leitura do servidor.
- **DeployEx:** o app `pipe_maestro`, na porta 4008.
- **HAProxy:** 14008.
- **nginx e certificado:** `pipemaestro.app`. O `www` responde 301.

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

```bash
cp .env.example .env    # uma vez: DEPLOY_USER e SUN_IP
git push                # o servidor busca do origin (Forgejo)
make deploy             # make ci, build no Sun e espera o rollout
make deploy.skip-ci     # o mesmo sem o make ci; REF=<branch|tag> escolhe outra ref
```

O `scripts/deploy_sun.sh` faz três coisas:

1. copia o `scripts/deploy.sh` para o Sun;
2. roda esse script lá, e ele:
   - alinha o clone com `origin/<ref>`;
   - compila a release `pipe_maestro` com a versão `<mix>-<sha>`;
   - entrega o tarball ao DeployEx, que roda `PipeMaestro.Release.migrate` antes de subir a
     versão nova;
3. consulta `https://pipemaestro.app/version` até a release nova responder. Desiste depois de
   `ROLLOUT_TIMEOUT_S`, que por padrão é 300 segundos.

## Primeira vez

O primeiro operador do backoffice é criado dentro do nó que está rodando, porque é ele que tem
o ambiente do DeployEx (`DATABASE_URL` e os segredos). Abra o console remoto do app
`pipe_maestro` no dashboard do DeployEx e rode:

```elixir
PipeMaestro.Release.create_operator("voce@exemplo.com", "Nome", "uma senha longa")
```

A release fica em `/var/lib/deployex/service/pipe_maestro/<instância>/current`. Um
`bin/pipe_maestro eval` aberto por SSH não tem o ambiente do app e falha ao configurar o banco.

Os workspaces e os usuários saem do backoffice. Cada runner se conecta com:

```bash
pipemaestro login --url https://pipemaestro.app
pipemaestro start --root ~/src
```

## Operar

Na pasta da infra:

- `make logs-pipemaestro` mostra o log do app;
- `make check-urls` testa o HTTPS de todos os domínios;
- o dashboard do DeployEx mostra a versão no ar, o histórico de deploys e permite o rollback.
