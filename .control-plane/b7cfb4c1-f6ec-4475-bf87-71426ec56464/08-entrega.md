# 08 — Entrega

## Branch
`cp/atualizar-runner-automaticamente-b7cfb4c1`, publicada em `origin` (Forgejo) com `git push -u origin HEAD`. Sem force-push, sem push para `main`, sem `gh`. PR não aberto: a abertura é feita por uma pessoa.

Link para abrir o PR:
https://git.rodrigomarchi.me/rodrigomarchi/pipemaestro/compare/main...cp/atualizar-runner-automaticamente-b7cfb4c1

## Verificações antes do push
- Branch atual confirmada: `cp/atualizar-runner-automaticamente-b7cfb4c1` (não é `main`).
- Tentativa anterior falhou no gate `test -z "$(git status --porcelain)"`: o único item não rastreado era este próprio artefato `08-entrega.md`. Os artefatos das etapas 01 a 07 estão versionados na branch, então este também é commitado, com caminho exato, como último commit (`Registro da etapa de entrega`). Nada mais estava pendente.
- Mensagens dos commits em português e descritivas (revisadas com `git log --oneline`).
- Histórico reescrito: nenhum.

## Commits (`git log --oneline $(git merge-base HEAD main)..HEAD`, do mais antigo ao mais novo)
- `71ab887` Entendimento e plano: atualizar runner automaticamente
- `1ce48bf` test: atualização automática do runner (testes que falham)
- `58b2883` feat: contrato do diretório de binários do runner no protocolo
- `97820f0` feat: runner se atualiza quando a plataforma está em outra versão
- `6b532eb` docs: ADR 0025, atualização automática do runner
- `0b51b46` fix: tipo no_return na reexecução do runner atualizado
- `d4b632f` Implementação: atualizar runner automaticamente
- `d895080` docs: revisão de convenções da atualização automática do runner
- `e7b8430` CI verde: atualizar runner automaticamente
- `2749e3f` Telas (e2e): atualizar runner automaticamente
- `d8cf4db` docs: índice da ADR 0025, roadmap e resumo da atualização automática do runner
- último commit: `Registro da etapa de entrega` (este arquivo; o SHA aparece no `git log` da branch)

## Resumo para a descrição do PR (Forgejo)

### O que mudou e por quê
Desde a ADR 0023, um runner fora da versão da plataforma é recusado e a pessoa troca o binário à mão a cada deploy (e um serviço fica em loop de reinícios). Agora o runner, ao ser recusado, oferece atualizar-se sozinho.

### Por app
- **`pipe_maestro_protocol`**: novo `PipeMaestroProtocol.Downloads` (alvos, nome do binário, `SHA256SUMS`, `parse_checksums/1`), o contrato do diretório de `download_url`. Nada no fio muda.
- **`pipe_maestro_runner`**: novos `SelfUpdate` (alvo, validação da origem, download com SHA-256, troca atômica por arquivo temporário e `rename`, reexecução) e `Update.handle/2` (pergunta `[S/n]`). `start` e `login` aceitam `--auto-update`; `service install` grava `start --auto-update` para o binário. `Output` ganha `ask/1`, `tty?/0` e `progress/1`.
- **`pipe_maestro_web`**: `RunnerComponents` lê os alvos do protocolo (HTML e `data-testid` iguais); `RunnerUpdate` só ganha documentação.
- **`pipe_maestro` (domínio)**: sem mudança, sem migração.
- **Telas**: nenhuma muda. O e2e (fluxo E) confere a pergunta e a resposta "não" via `config/e2e.exs` (`:update_prompt`, só em `MIX_ENV=e2e`).

### Protocolo
Formato das mensagens e `protocol_version` **não mudam**. O `download_url` passa a ter convenção documentada: diretório com `pipemaestro_<alvo>` e `SHA256SUMS`. **Runners antigos** recebem a mesma recusa de hoje, mostram a mensagem e saem; só os runners com esta feature se atualizam. A primeira atualização automática ocorre no deploy seguinte ao que publicar esta versão, e serviços já instalados precisam rodar `service install` de novo.

### Riscos e pontos de atenção
- **Reexecução no terminal** (`Port` com `:nouse_stdio`) e Ctrl+C: não há teste de TTY real no CI; validar com o binário real. O fallback ("rode de novo") está previsto na ADR.
- **Detecção de TTY** em `-noshell` no OTP do binário: confirmar.
- **Segurança**: só mesma origem, `https` (loopback aceita `http`), sem redirects; o SHA-256 vem do mesmo servidor, protege contra corrupção e não contra servidor comprometido (assinatura é pendência, ver ADR).
- `RUNNER_DOWNLOADS_URL` absoluto em outra origem desativa a auto-atualização (documentado em `deploy.md`).
- `test_ignore_filters` em `apps/pipe_maestro_runner/mix.exs` para `test/support/`.

### Como verificar
- `make ci` (passou) e `make e2e` / `make e2e.shots FILE=tests/runner-connection.spec.ts` (passaram).
- Manual: `make runner.binary`, servir o diretório de binários de uma "plataforma" em outra versão, rodar `pipemaestro start`; conferir a pergunta, o "sim", a troca, a reexecução e o Ctrl+C; repetir com "não", sem TTY e com `--auto-update`.

### ADRs e documentos
- ADR nova: `docs/adr/0025-atualizacao-automatica-do-runner.md` (indexada em `docs/README.md`).
- Atualizados: `docs/specs/protocolo-runner.md`, `docs/guias/instalacao.md`, `docs/guias/deploy.md`, `docs/plano/03-roadmap-orquestrador.md` (Marco 5).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

## Pendências para a pessoa revisora
- Validar a reexecução e o Ctrl+C com o binário real em terminal (não coberto pelo CI).
- Confirmar a detecção de TTY em `-noshell` no OTP do binário.
- Assinatura dos binários continua pendente (ver ADR 0025).

## Status
ok — branch pronta para revisão humana; PR a ser aberto por uma pessoa.
