# 0002 — Identidades, workspaces e backoffice

- **Status:** aceita
- **Data:** 03/11/2026

## Contexto

Primeiro passo real de multi-tenant: operadores da plataforma criam os workspaces
das empresas e os usuários (e-mail e senha) e administram o acesso deles. O login
do cliente passa a ser de verdade. Não há auto-cadastro.

## Decisões

1. **Duas identidades separadas.** `Backoffice.Operator`, com as tabelas
   `operators` e `operators_tokens`, entra em `/backoffice`. `Accounts.User`, com
   `users` e `users_tokens`, entra em `/login`. São chaves de sessão, plugs,
   `on_mount` e rotas diferentes. Credencial de usuário nunca abre o backoffice,
   e vice-versa. Operadores criam outros operadores; o primeiro nasce de
   `ClaudeControlPlane.Release.create_operator/3` (ou de
   `mix control_plane.create_operator`).
2. **Um usuário pode estar em vários workspaces**, via `workspace_memberships`.
   Depois do login, `/workspaces` leva direto ao workspace quando há um só e
   mostra o seletor quando há vários. O workspace atual fica no `Scope`
   (`Accounts.Scope`), que é a fronteira de tenant passada explicitamente.
   Ainda não há papéis dentro do workspace.
3. **Autenticação escrita à mão** no desenho do `phx.gen.auth` do Phoenix 1.8:
   - token aleatório na sessão, com só o hash SHA-256 gravado no banco;
   - `renew_session` no login e no logout, contra session fixation;
   - bcrypt, com verificação em tempo constante quando o e-mail não existe.

   Não usamos o gerador porque ele traz magic link, mailer, auto-cadastro e troca
   de e-mail, que não queremos.
4. **Validade da sessão:** a do usuário dura 14 dias, com cookie "manter
   conectado". A do operador dura 12 horas, sem remember-me.
5. **Revogação imediata.** Desativar um usuário ou operador, ou redefinir a senha
   de um usuário, apaga todos os tokens dele. Uma mensagem de PubSub
   (`user_sessions:<id>` / `operator_sessions:<id>`) tira da tela as LiveViews
   abertas. Não usamos `live_socket_id` porque o cookie de sessão é compartilhado
   entre as duas identidades e só comporta um.
6. **IDs UUID** em todas as tabelas, para que IDs de tenant não sejam
   enumeráveis. E-mail em `citext`.

## Fora deste passo

- Rate limit de tentativas de login.
- 2FA para operadores.
- Trilha de auditoria das ações do backoffice.
- Papéis dentro do workspace.
- Convite e redefinição de senha por e-mail.
- Isolamento por RLS no Postgres.
