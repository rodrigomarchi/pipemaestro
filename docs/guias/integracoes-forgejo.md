# Conectar um Forgejo

Como ligar uma instância do Forgejo (ou o Codeberg) a um workspace, para que issues
virem tarefas e o andamento volte para a issue e para o pull request. As decisões estão
no [ADR 0034](../adr/0034-integracoes-com-hosts-git.md); as regras, na
[spec](../specs/integracoes.md).

## 1. Escolher como a plataforma entra

O Forgejo não tem apps como o GitHub: a plataforma sempre age como um usuário.

- **Token de um usuário-bot (recomendado).**
  1. Crie um usuário para a plataforma, como `pipemaestro-bot`.
  2. Dê a ele acesso de escrita aos repositórios: colaborador, ou membro de um time da
     organização.
  3. Entre como ele e, em Configurações → Aplicações, gere um token com `write:issue`,
     `write:repository` e `read:user`.
  4. No Forgejo 15 ou mais novo, restrinja o token aos repositórios que vai vincular.
     Um token restrito não cria webhooks: nesse caso, crie o webhook à mão (seção 3).
- **OAuth.** Em Configurações → Aplicações, crie uma aplicação OAuth2 com a URL de
  redirecionamento que a tela de Integrações mostra
  (`https://<plataforma>/integrations/oauth/callback`). A conexão age como quem autorizar.

## 2. Conectar e vincular

1. Em Integrações → Nova conexão, informe o nome, o endereço da instância e o token,
   ou o Client ID e o Client Secret do OAuth.
2. Escolha quem chama o Forgejo:
   - **a plataforma** (padrão): reage, comenta, põe labels, mostra cada etapa como commit
     status e mantém o pull request;
   - **o runner**: para uma instância que a plataforma não alcança, mas que alcança a
     plataforma. Nesse modo só a label dispara uma tarefa, e o retorno na issue
     acontece junto das etapas.
3. Vincule cada repositório a um projeto. A plataforma cria as labels
   `pipemaestro:*` e, se o token tiver permissão de admin no repositório, o webhook.
4. Defina os gatilhos do repositório:
   - label adicionada;
   - comando em comentário (`/pipemaestro`);
   - toda issue nova.

   Com triagem, a IA escreve a tarefa e, por padrão, ela já começa.

## 3. Webhook manual

Se o repositório ficou com "webhook manual", crie em Configurações → Webhooks →
Forgejo:

- **URL:** a da conexão (`https://<plataforma>/api/integrations/<conexão>/webhook`);
- **content type:** `application/json`;
- **segredo:** o da conexão ("Mostrar segredo");
- **eventos:** issues, comentários de issue, pull requests e reviews de pull request.

## 4. O que conferir no Forgejo

- `[webhook] ALLOWED_HOST_LIST`: o padrão (`external`) aceita a plataforma num endereço
  público. Numa rede interna, inclua o host da plataforma.
- **Forgejo numa rede interna:** a plataforma recusa chamar um endereço privado, loopback
  ou link-local. Uma plataforma self-hosted na mesma rede do Forgejo libera isso com
  `INTEGRATIONS_ALLOW_PRIVATE_HOSTS=true`.
- O Forgejo espera 5 s pela resposta e não reenvia uma entrega que falhou. A plataforma
  responde na hora e, a cada cinco minutos, lê as issues alteradas para pegar o que um
  webhook perdeu.
- As entregas recebidas, com o motivo de cada uma, ficam em Integrações → a conexão →
  Entregas, de onde dá para reprocessar.
