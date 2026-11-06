# 0038 — Atualização automática por padrão

- **Status:** aceita
- **Data:** 06/11/2026
- **Altera:** [ADR 0025](0025-atualizacao-automatica-do-runner.md)

## Contexto

Pela [ADR 0025](0025-atualizacao-automatica-do-runner.md), o binário único recusado por
versão pergunta no terminal se deve atualizar, e só atualiza sem perguntar com
`--auto-update`. Sem terminal e sem a opção, mostra a mensagem e sai. A cada deploy, quem
roda o runner num terminal precisa estar lá para responder, e quem roda sem terminal fora
do serviço instalado fica parado até perceber (issue #20).

## Decisão

- **Atualizar é o padrão do binário único**, com e sem terminal: recusado por versão (no
  `login` ou em qualquer join), ele baixa, confere, troca o binário e roda o mesmo comando
  de novo, sem perguntar. No terminal, o binário novo herda o terminal; sem ele, o runner
  sai com 0 para o gerenciador de serviços subir o novo.
- **`--no-auto-update` desliga.** No `start` e no `login`, a opção restaura o
  comportamento anterior: no terminal, a pergunta `[S/n]`; sem terminal, a mensagem da
  [ADR 0023](0023-runner-na-versao-da-plataforma.md).
- **`--auto-update` segue aceito**, sem efeito além do padrão: serviços instalados antes
  desta decisão gravaram `start --auto-update` e continuam funcionando sem reinstalar.
- **`pipemaestro service install` grava só `start`.**
- **Inalterados:** sob Mix e numa release sem Burrito o runner não se atualiza; a origem
  única, o `https`, o SHA-256 contra o `SHA256SUMS`, a troca atômica e a mensagem de
  "sem permissão de escrita" seguem a ADR 0025.
- **E2E.** A chave `:update_prompt` de `config/e2e.exs` segue fazendo o runner agir como
  um binário único num terminal; as specs passam `--no-auto-update` para ele perguntar e
  responderem "não", em vez de tentar baixar.

## Consequências

- Um deploy não exige ninguém em nenhuma máquina: o runner se atualiza sozinho.
- O binário passa a trocar o executável sem confirmação. As garantias são as da ADR 0025
  (origem, `https`, SHA-256, troca atômica); quem quer controle manual usa
  `--no-auto-update`.
- O protocolo não muda: o payload de recusa `"outdated"` é o mesmo e `protocol_version`
  não sobe. Runners anteriores a esta versão se comportam como antes até se atualizarem.
