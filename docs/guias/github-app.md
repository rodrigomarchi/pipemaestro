# O GitHub App da plataforma

O GitHub se conecta por um GitHub App da instalação do PipeMaestro: cada workspace
instala o App na sua conta ou organização e escolhe os repositórios. As decisões estão
no [ADR 0036](../adr/0036-integracoes-com-hosts-git.md) e no
[ADR 0037](../adr/0037-credencial-git-por-job.md).

## 1. Registrar o App (uma vez por instalação da plataforma)

Em GitHub → Settings → Developer settings → GitHub Apps → New GitHub App:

| Campo | Valor |
|---|---|
| Homepage URL | `https://<plataforma>` |
| Callback URL | `https://<plataforma>/integrations/github/setup` |
| Request user authorization (OAuth) during installation | **ligado**: confirma que quem instalou alcança a instalação |
| Setup URL | `https://<plataforma>/integrations/github/setup` (com "Redirect on update") |
| Webhook URL | `https://<plataforma>/api/integrations/github/webhook` |
| Webhook secret | um valor aleatório |

Permissões do repositório:

| Permissão | Nível |
|---|---|
| Metadata | Read |
| Issues | Read and write |
| Pull requests | Read and write |
| Contents | Read and write |
| Checks | Read and write |

Eventos:
- Issues;
- Issue comment;
- Pull request;
- Pull request review;
- Check run (o botão "Refazer etapa").

Depois de criar o App, gere uma chave privada e um client secret.

## 2. Configurar a plataforma

| Variável | Valor |
|---|---|
| `GITHUB_APP_ID` | o App ID |
| `GITHUB_APP_SLUG` | o nome na URL do App (`github.com/apps/<slug>`) |
| `GITHUB_APP_CLIENT_ID` | o Client ID |
| `GITHUB_APP_CLIENT_SECRET` | o client secret |
| `GITHUB_APP_PRIVATE_KEY` | o conteúdo do `.pem` da chave privada |
| `GITHUB_APP_WEBHOOK_SECRET` | o segredo do webhook |
| `GITHUB_API_URL`, `GITHUB_WEB_URL` | só no GitHub Enterprise Server: `https://<host>/api/v3` e `https://<host>` |

Sem essas variáveis, a opção GitHub não aparece em Integrações.

## 3. Como funciona

- **Conectar:** em Integrações → Nova conexão → GitHub, salvar leva à instalação do
  App. O GitHub devolve a pessoa com a instalação e um login, e a plataforma confere
  que ela administra a conta da instalação (a própria conta ou uma organização em que é
  admin) antes de ativar a conexão. Uma instalação serve a uma conexão só.
- **Tokens:** cada chamada usa um token da instalação, que dura uma hora. Cada job de
  etapa leva ao runner um token só do repositório da tarefa, com `contents: write`.
- **Webhook:** um só, o do App, para todas as instalações. O GitHub não reenvia uma
  entrega que falhou; a reconciliação pede de novo as que falharam nos últimos três dias.
- **Retorno:** cada etapa vira um check run no último commit empurrado. O pull request
  nasce em rascunho e fica pronto na última etapa.
- **Gatilhos que vieram dos projetos:** o antigo webhook por workspace
  (`/api/github/webhook/<workspace>`) saiu. Cada projeto com gatilho virou um
  repositório vinculado de uma conexão GitHub pendente, que volta a funcionar quando o
  App é instalado. O segredo `GITHUB_WEBHOOK_SECRET` dos workspaces não é mais usado e,
  como os segredos chegam aos runners, deve ser apagado em Segredos.
