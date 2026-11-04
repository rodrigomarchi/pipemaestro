# 0009 — Perfis de permissão, credencial do agente e operação do runner

- **Status:** aceita; os perfis de permissão foram substituídos pelo [ADR 0018](0018-etapas-autonomas.md)
- **Data:** 03/11/2026
- **Roadmap:** Marco 1, itens 6 a 9, de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)

## Contexto

O runner rodava toda etapa com permissões totais e com o login pessoal de quem roda o
`claude`. Não havia como saber, olhando a plataforma, com qual credencial uma etapa
rodou, nem como diagnosticar uma máquina ou mantê-la online sem um terminal aberto.

## Decisões

1. **Perfil de permissão por etapa**, enviado no job (`permissions`) e traduzido pelo
   runner em opções do CLI:

   | Perfil | O agente pode | Opções do CLI |
   |---|---|---|
   | `total` (padrão) | tudo | `--dangerously-skip-permissions` |
   | `edicao` | editar arquivos; o resto só se liberado | `--permission-mode acceptEdits --permission-prompts none` |
   | `leitura` | ler, buscar e escrever em `.control-plane/` (o próprio artefato) | `--permission-mode dontAsk --permission-prompts none` |

   - Fora do perfil total, os comandos de teste e de lint do projeto vêm liberados
     (`Bash(<comando>:*)`), e cada etapa pode liberar ou negar outras regras.
   - O artefato usa uma regra `Edit(./.control-plane/**)`. Conferimos no CLI 2.1.317
     que só regras `Edit` valem para escrita de arquivos.
   - Nos templates, triagem, investigação e auditoria passam a ser `leitura`.
2. **Credencial visível.**
   - O runner anuncia no `Hello` o `agent`: a versão do CLI e se usa uma chave de API
     própria (`api_key`) ou o login da máquina (`login`). A página de runners mostra, e
     o login pessoal aparece como aviso.
   - Cada execução registra no evento de sessão a origem da credencial
     (`apiKeySource`) e o modo de permissão.
   - A chave própria vem de `RUNNER_ANTHROPIC_API_KEY` no ambiente do runner e vai
     ao CLI como `ANTHROPIC_API_KEY`. Nunca passa pelo control plane.
3. **`runner.doctor`.** Verifica, com ação sugerida para cada problema:
   - o agente e a credencial;
   - o git e as credenciais do runner;
   - a raiz e os diretórios;
   - o disco;
   - se a plataforma responde em `/healthz`.

   A página de runners já mostra o equivalente (agente, diretórios, worktrees e
   disco), então o relatório não é enviado.
4. **Runner como serviço do usuário.** `runner.service` gera e instala um LaunchAgent
   (macOS) ou uma unit de usuário do systemd (Linux):
   - roda `mix runner.start` no app do runner;
   - sobe no login e reinicia sozinho;
   - escreve o log em `runner.log`, ao lado das credenciais.

## Consequências

- A outbox continua em memória (ADR 0006): um restart do serviço perde o que não foi
  confirmado. Isso só pesa para um job que terminou durante a queda e antes do
  restart, já que os jobs em execução morrem com o processo de qualquer forma.
  Persistir a outbox fica para quando houver um caso real.
- O protocolo ganha `permissions` no `Job` e `agent` no `Hello`, de forma aditiva.
