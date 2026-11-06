# 0035 — Credencial git por job

- **Status:** aceita
- **Data:** 06/11/2026
- **Relacionada:** [ADR 0027](0027-entrega-em-pr-no-forgejo.md), [ADR 0034](0034-integracoes-com-hosts-git.md)

## Contexto

O push da tarefa usava o que o git da máquina do runner tivesse: o chaveiro, o `gh` ou um
`FORGEJO_TOKEN` nos segredos do workspace, que chega ao agente junto com todos os outros
segredos. Um runner como serviço, de um cliente, não tem a credencial de uma pessoa, e não
deveria precisar dela.

## Decisões

1. **O job de etapa leva a credencial do repositório** (`git_credential` no
   `PipeMaestroProtocol.Job`: `host`, `username`, `password`, `expires_at`).
   - Vem da conexão do repositório vinculado: o token do bot, o access token do OAuth ou,
     no GitHub, um token de instalação de 1 h restrito ao repositório com `contents: write`.
   - Só vai para um runner que anuncia a capability `git_credential` no `Hello`. Um runner
     antigo segue como antes. Uma proposta (triagem) nunca a recebe, porque lê o texto de
     uma issue.
2. **O runner a entrega ao git por um helper**, nunca pela URL do remoto.
   - Grava a credencial num arquivo `0600` por job e configura, por variáveis
     `GIT_CONFIG_*`, um `credential.https://<host>.helper` que lê esse arquivo.
   - Vale para os comandos git do próprio runner e para o processo do agente, que também
     pode fazer o push (ADR 0033).
   - O arquivo é apagado no fim do job, e os que sobraram são apagados no início do runner.
3. **Renovação por push do servidor.** Uma credencial com `expires_at` é renovada pelo
   canal com `job:credential`, alguns minutos antes de vencer, enquanto o job roda. O
   runner regrava o arquivo de forma atômica. O runner não pede: assim não precisa de
   requisição com resposta no canal.
4. **A senha entra nas verificações da plataforma.** A verificação "nenhum segredo nas
   mudanças" passa a incluir a senha da credencial.

## Consequências

- O protocolo muda de forma aditiva e `protocol_version` não sobe.
- O `gh` e o login de quem roda o runner continuam valendo só para tarefas sem repositório
  vinculado.
- O token de um bot do Forgejo não vence: ele chega ao runner do cliente, que é a máquina
  do próprio cliente. Um token restrito aos repositórios (Forgejo v15+) limita o alcance.
