# 0025 — Atualização automática do runner

- **Status:** aceita; o padrão (atualizar sem perguntar) foi alterado pela [ADR 0038](0038-atualizacao-automatica-por-padrao.md); a execução do binário novo foi alterada pela [ADR 0043](0043-runner-resiliente-a-reinicios.md)
- **Data:** 04/11/2026

## Contexto

Desde a [ADR 0023](0023-runner-na-versao-da-plataforma.md), só conecta o runner que está
na versão da plataforma. A cada deploy, todo runner é recusado e a pessoa precisa abrir
Executores, baixar o binário, trocar o antigo e rodar de novo. Num runner instalado como
serviço, isso vira um loop de reinícios até alguém perceber. O deploy já publica os
binários do mesmo commit, um por alvo, com um `SHA256SUMS`
([ADR 0020](0020-binarios-do-runner-no-deploy.md)).

## Decisão

- **Atualizar na recusa.** Recusado por versão (no `login` ou em qualquer join), o
  binário único pergunta `Baixar e instalar a versão X agora? [S/n]`. "Sim" (ou Enter)
  baixa, confere, troca o binário e roda o mesmo comando de novo. "Não" mantém a mensagem
  da ADR 0023. `--auto-update` atualiza sem perguntar, e `pipemaestro service install`
  grava `start --auto-update`.
- **Quando não atualiza.** Sob Mix (`make runner.*`, o código vem do `git`), numa release
  sem Burrito (`bin/pipemaestro`) e sem terminal sem `--auto-update`: a mensagem da ADR
  0023. O binário único se reconhece por `__BURRITO_BIN_PATH`, que o wrapper do Burrito
  exporta.
- **Origem única.** O runner só baixa de um `download_url` na mesma origem (esquema,
  host e porta) da plataforma a que conecta, e com `https`. `http` só vale para host de
  loopback (dev, e2e, testes). Redirecionamentos não são seguidos. Fora disso, ele mostra
  a mensagem da ADR 0023.
- **Convenção do `download_url`, sem campo novo no protocolo.** O `download_url` é um
  diretório com `pipemaestro_<alvo>` por alvo e um `SHA256SUMS` no formato do
  `sha256sum` (`PipeMaestroProtocol.Downloads`). Um campo com URLs por alvo exigiria a
  mesma validação de origem e só repetiria a convenção. `protocol_version` não sobe.
- **SHA-256 contra o `SHA256SUMS`.** Protege contra download parcial e corrompido, não
  contra um servidor comprometido: o `SHA256SUMS` vem do mesmo servidor. Assinar os
  binários fica como pendência.
- **Troca atômica.** O binário novo é escrito num temporário no mesmo diretório
  (`.<nome>.update-<aleatório>`), sincronizado, com `0755`, e renomeado sobre o atual.
  O `rename` cria um inode novo, o que evita o SIGKILL do macOS ao sobrescrever um
  executável assinado. Qualquer erro apaga o temporário e deixa o binário atual como
  estava. A partida do `start` apaga temporários que tenham sobrado. Sem permissão de
  escrita no diretório, o runner mostra o caminho e os comandos para fazer à mão, sem
  `sudo`.
- **Rodar de novo.** A BEAM não tem `execve`. No terminal, o runner abre o binário novo
  com `Port.open/2` e `:nouse_stdio`: o filho herda o terminal, e o processo antigo sai
  com o código dele. O filho não herda as variáveis da release descompactada do antigo
  (`__BURRITO*`, `RELEASE_*`, `ROOTDIR`, `BINDIR`, `EMU`, `PROGNAME`). No serviço, o
  runner sai com 0 e o launchd (`KeepAlive`) ou o systemd (`Restart=always`) sobe o
  binário novo. Se a herança do terminal falhar em algum alvo, a alternativa é trocar o
  binário e pedir para rodar de novo.
- **Chave de teste do e2e.** O e2e roda o runner pelo Mix e sem terminal, onde ele
  nunca pergunta. `config :pipe_maestro_runner, :update_prompt, binary: <caminho>`, só em
  `config/e2e.exs`, faz o runner perguntar como um binário único num terminal, para o e2e
  responder "não".

## Consequências

- Um deploy deixa de exigir intervenção em cada máquina: no terminal, um Enter; no
  serviço, nada.
- Runners anteriores a esta decisão recebem o mesmo payload e saem como antes. A
  primeira atualização automática acontece no deploy seguinte ao que publicar esta
  versão. Quem instalou o serviço antes precisa rodar `pipemaestro service install` de
  novo, para ganhar o `--auto-update`.
- Um `RUNNER_DOWNLOADS_URL` em outra origem (um CDN) desliga a atualização automática.
  Servir de outro lugar exigirá outra ADR, com um campo aditivo e assinatura.
