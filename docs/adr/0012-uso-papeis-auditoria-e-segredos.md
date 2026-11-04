# 0012 — Uso, papéis, auditoria, manutenção, alertas e segredos

- **Status:** aceita
- **Data:** 03/11/2026
- **Roadmap:** Marco 4 de [`03-roadmap-orquestrador.md`](../plano/03-roadmap-orquestrador.md)

## Contexto

Com o orquestrador completo (Marcos 1 a 3), faltava operá-lo como produto:

- saber quanto custa e onde o custo está;
- separar quem configura de quem usa;
- registrar quem fez o quê;
- manter o banco limpo;
- avisar do que está parado;
- dar aos agentes credenciais sem espalhá-las.

## Decisões

1. **Uso a partir dos jobs** (`PipeMaestro.Usage`). A conta considera os jobs que
   rodaram e terminaram no período; um job cancelado na fila não rodou. A tela mostra,
   para 7 ou 30 dias:
   - custo, execuções e tempo de agente;
   - o custo por dia;
   - a quebra por pipeline, runner e pessoa;
   - por etapa, com as execuções que falharam (as retentativas).
2. **Dois papéis por workspace**, `admin` e `member` (`PipeMaestro.Authorization`).
   - Admins gerenciam pipelines, projetos, runners e segredos, veem a auditoria e
     cancelam qualquer tarefa.
   - Todos criam, acompanham e decidem tarefas e cancelam as próprias.
   - O primeiro membro de um workspace vira admin. Quem já era membro antes dos
     papéis virou admin, para ninguém perder acesso.
   - O backoffice troca papéis, e a aprovação de runner exige admin no domínio.
3. **Auditoria** (`audit_events`). Registra quem criou, decidiu e cancelou tarefas,
   quem salvou, importou e removeu pipelines e projetos, quem aprovou, renomeou e
   revogou runners, e quem salvou e removeu segredos.
   - O domínio registra onde já conhece o autor (tarefas, aprovação de runner); as
     telas registram o resto com uma chamada.
   - Guarda o nome do objeto na hora, então o registro sobrevive à remoção.
4. **Manutenção num processo periódico, não no Oban.** Um `GenServer` por nó roda de
   hora em hora:
   - apaga os pedidos de login de runner vencidos há mais de um dia;
   - apaga os eventos de jobs que terminaram há mais de 30 dias (o job mantém
     desfecho, custo e artefato);
   - apaga a auditoria com mais de um ano.

   Com um nó só, uma fila persistente não se paga; com vários, entra o Oban. O pedido
   de código do device flow ganha limite por endereço: 10 por minuto, numa janela em
   ETS.
5. **Alertas no board.** O board passa a mostrar:
   - tarefa em execução cujo runner está offline (está parada);
   - tarefa que já gastou 80% ou mais do orçamento.

   As notificações do ADR 0010 continuam cobrindo pausas e fins.
6. **Segredos do workspace como variáveis de ambiente** (`PipeMaestro.Secrets`).
   - Ficam cifrados com AES-256-GCM, com chave em `SECRETS_KEY` em produção.
   - Vão ao runner com cada job, só no envio: não ficam no job nem no runner.
   - O MCP de um pipeline os usa como `${NOME}`.
   - Nomes que o runner usa (`PATH`, `HOME`...) são recusados, e a tela nunca mostra
     os valores.

## Consequências

- Produção precisa de `SECRETS_KEY`; trocá-la torna os segredos guardados ilegíveis.
- O protocolo ganha `env` no `Job`, de forma aditiva.
- Responsável e prazo de uma decisão (ADR 0011) continuam pendentes: os papéis
  existem, mas não há fila de responsáveis.
