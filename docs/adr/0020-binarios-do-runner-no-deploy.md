# 0020 — Binários do runner gerados em contêiner e publicados no deploy

- **Status:** aceita; ajustada pela [ADR 0035](0035-versao-propria-do-runner.md): os binários só são gerados quando a versão do runner muda
- **Data:** 04/11/2026

## Contexto

Até aqui o binário único do runner (Burrito, ADR 0014) só saía da máquina de quem
desenvolve, com Zig, xz e um Erlang 28.5 instalados à parte. Quem conecta um runner
à produção precisa baixá-lo da mesma versão do control plane no ar.

O Burrito empacota, para cada alvo, o ERTS pré-compilado da **versão exata** do OTP
que faz o build (`Burrito.Util.get_otp_version/0`, que lê o `OTP_VERSION`). Ele baixa
esse ERTS de `beam-machine-universal.b-cdn.net`, e o CDN não publica todo patch. O
Sun e as máquinas de desenvolvimento rodam o 28.5.0.8 (`.tool-versions`), que o CDN
não tem, enquanto o 28.5.0.6 está publicado. A infra mantém um Erlang só por
servidor, e o Erlang local e o do servidor precisam ser o mesmo.

## Decisão

- **Uma imagem de build** (`docker/runner-binary/Dockerfile`):
  - parte de `erlang:28.5.0.6`, uma versão que o CDN publica;
  - traz o Elixir 1.20.4, o Zig 0.16 e o xz;
  - serve a quem desenvolve (`make runner.binary`) e ao servidor (`scripts/deploy.sh`).

  Em Linux, o Burrito gera os quatro alvos, macOS inclusive. O Erlang dos hosts não
  muda.
- **O binário usa o próprio ERTS.** Ele leva o 28.5.0.6 e fala com o control plane
  por WebSocket, nunca pela distribuição Erlang, então a diferença de patch não
  importa.
- **O deploy gera os binários do mesmo commit** e os publica em
  `/var/www/pipemaestro/downloads/runner/`, servidos pelo nginx em
  `/downloads/runner/` com nome estável (`pipemaestro_<alvo>`), mais um
  `SHA256SUMS`.
  - A versão gravada no binário é a do commit, a mesma do `/version` do control
    plane.
  - Uma falha no build interrompe o deploy antes do DeployEx.
- **A tela de runners** mostra os links quando `RUNNER_DOWNLOADS_URL` está
  configurado (em produção), e o modal "Conectar runner" passa a ensinar a baixar,
  fazer login e iniciar.
- **O login sem `--url` usa a produção**, https://pipemaestro.app
  (`PipeMaestroProtocol.default_platform_url/0`), ou `$PIPEMAESTRO_URL`.

## Consequências

- Quando o CDN do Burrito publicar um patch novo, só o `ARG OTP_IMAGE` da imagem
  muda.
- O build dos binários aumenta o tempo do deploy. A imagem e um volume de cache
  (`pipemaestro-runner-build-cache`, com deps, `_build` e os downloads do Burrito) o
  tornam incremental.
- Ninguém mais precisa de Zig nem de um segundo Erlang na máquina, só de Docker.
- Os binários não são assinados. Baixados por `curl`, o macOS não os põe em
  quarentena; pelo navegador, o Gatekeeper pede para liberar.
