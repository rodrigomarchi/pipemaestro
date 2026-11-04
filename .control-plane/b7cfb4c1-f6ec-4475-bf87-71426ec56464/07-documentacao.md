# 07 — Documentação e resumo para revisão

## O que mudou e por quê
Desde a ADR 0023, um runner fora da versão da plataforma é recusado e a pessoa troca o binário à mão a cada deploy (e um serviço fica em loop de reinícios). Agora o runner, ao ser recusado, oferece atualizar-se sozinho.

### Por app
- **`pipe_maestro_protocol`**: novo `PipeMaestroProtocol.Downloads` (alvos, nome do binário, `SHA256SUMS`, `parse_checksums/1`), o contrato do diretório de `download_url`. Nada no fio muda.
- **`pipe_maestro_runner`**: novos `SelfUpdate` (alvo, validação da origem, download com SHA-256, troca atômica por arquivo temporário e `rename`, reexecução) e `Update.handle/2` (pergunta `[S/n]`). `start` e `login` aceitam `--auto-update`; `service install` grava `start --auto-update` para o binário. `Output` ganha `ask/1`, `tty?/0` e `progress/1`.
- **`pipe_maestro_web`**: `RunnerComponents` lê os alvos do protocolo (HTML e `data-testid` iguais); `RunnerUpdate` só ganha documentação.
- **`pipe_maestro` (domínio)**: sem mudança, sem migração.
- **Telas**: nenhuma muda. O e2e (fluxo E) confere a pergunta e a resposta "não" via `config/e2e.exs` (`:update_prompt`, só em `MIX_ENV=e2e`).

## Protocolo
Formato das mensagens e `protocol_version` **não mudam**. O `download_url` passa a ter convenção documentada: diretório com `pipemaestro_<alvo>` e `SHA256SUMS`. **Runners antigos** recebem a mesma recusa de hoje, mostram a mensagem e saem; só os runners com esta feature se atualizam. A primeira atualização automática ocorre, portanto, no deploy seguinte ao que publicar esta versão, e serviços já instalados precisam rodar `service install` de novo.

## Riscos e pontos de atenção
- **Reexecução no terminal** (`Port` com `:nouse_stdio`) e Ctrl+C: não há teste de TTY real no CI; validar com o binário real. O fallback ("rode de novo") está previsto na ADR.
- **Detecção de TTY** em `-noshell` no OTP do binário: confirmar.
- **Segurança**: só mesma origem, `https` (loopback aceita `http`), sem redirects; o SHA-256 vem do mesmo servidor, protege contra corrupção e não contra servidor comprometido (assinatura é pendência, ver ADR).
- `RUNNER_DOWNLOADS_URL` absoluto em outra origem desativa a auto-atualização (documentado em `deploy.md`).
- `test_ignore_filters` em `apps/pipe_maestro_runner/mix.exs` para `test/support/`.

## Como verificar
- `make ci` (passou) e `make e2e` / `make e2e.shots FILE=tests/runner-connection.spec.ts` (passaram).
- Manual: `make runner.binary`, servir o diretório de binários de uma "plataforma" em outra versão, rodar `pipemaestro start`; conferir a pergunta, o "sim", a troca, a reexecução e o Ctrl+C; repetir com "não", sem TTY e com `--auto-update`.

## ADRs e documentos
- ADR nova: `docs/adr/0025-atualizacao-automatica-do-runner.md` (indexada em `docs/README.md`).
- Atualizados: `docs/specs/protocolo-runner.md`, `docs/guias/instalacao.md`, `docs/guias/deploy.md`, `docs/plano/03-roadmap-orquestrador.md` (Marco 5).
