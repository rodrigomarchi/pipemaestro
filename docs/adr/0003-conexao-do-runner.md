# 0003 — Login e conexão do runner

- **Status:** aceita
- **Data:** 03/11/2026

## Contexto

O runner (executor BYO) roda na infraestrutura do cliente e precisa de uma identidade
para se conectar ao control plane. Ele não pode depender da senha de uma pessoa e
não pode exigir porta de entrada na rede do cliente.

## Decisões

1. **Login por device flow (RFC 8628).** A CLI mostra uma URL e um código curto;
   um membro do workspace aprova no navegador, já logado; a CLI recebe um token
   próprio do runner. Isso funciona em servidor sem navegador, e a senha nunca
   passa pelo terminal. Alternativas descartadas: e-mail e senha na CLI (expõe a
   credencial pessoal numa máquina compartilhada) e um token de registro colado à
   mão (exige um passo manual a mais).
2. **Token do runner.** O formato é `cpr_` mais 32 bytes aleatórios. O banco guarda
   só o SHA-256. O token é emitido uma única vez, na troca do `device_code`, e
   revogar o runner o anula na hora.
3. **Conexão por Phoenix Channels** (cliente Slipstream no runner): o WebSocket
   parte do runner, e a presença usa `Phoenix.Presence` no tópico do workspace. Não
   usamos distribuição Erlang (NAT, cookie compartilhado, acoplamento) nem
   long-poll HTTP.
4. **O contrato fica no app `protocol`.** A struct `Hello`, os caminhos, o tópico, os
   códigos de erro e as versões aceitas ficam ali. Runner e control plane dependem
   dele e de nada um do outro. A spec escrita é `docs/specs/protocolo-runner.md`.
5. **CLI em mix tasks** por enquanto (`runner.login|start|status|logout`), rodando
   no diretório do app do runner para que o control plane não suba junto. A release
   e o binário único (Burrito) ficam para quando houver distribuição para clientes.
6. **O runner não se conecta sozinho ao subir o app.** No dev, o
   `mix phx.server` sobe todos os apps do umbrella; quem abre a conexão é o
   `runner.start`.

## Fora deste passo

- Execução de jobs, dispatcher, leases e containers.
- Rate limit no device flow.
- Limpeza das autorizações expiradas (job do Oban).
- Papéis: definir quem pode aprovar ou revogar runners. Hoje qualquer membro pode.
