# 07 — Documentação e resumo

## Documentação

- **Sem ADR novo.** A decisão é a extensão que o próprio ADR 0029 anunciava, então ele foi estendido na etapa 3. O índice `docs/README.md` continua certo, porque o número e o título não mudaram.
- **`docs/adr/0029-questionario-de-decisao.md`:** o item "A proposta de tarefa usa o mesmo questionário" e a consequência sobre propostas antigas, que continuam lidas como estão.
- **`docs/specs/integracoes.md`:** o comentário de triagem sem tarefa lista as perguntas numeradas com as opções e a recomendada, e manda responder pelo link da proposta.
- **Conferidos, sem mudança:** `docs/specs/protocolo-runner.md` (o protocolo não mudou), `docs/guias/ui-petal.md`, `docs/guias/phoenix.md`, `e2e/README.md` (os ids seguem o padrão por sufixo) e `docs/plano/`. Uma busca em `docs/` não achou outra menção às perguntas da proposta de tarefa.
- Nenhum arquivo de `apps/` mudou nesta etapa.

## Resumo para quem revisa

**O que mudou e por quê.** Quando a IA escreve uma tarefa e não a acha pronta, ela agora pergunta no questionário estruturado do ADR 0029, em vez de uma lista de frases. A pessoa responde na página da proposta, e as respostas pedem uma nova rodada que reescreve a tarefa.

- **`apps/pipe_maestro`:**
  - `TaskKind` usa o schema de perguntas das etapas, separa `questions` (estruturadas) de `legacy_questions` (frases antigas) e aceita feedback de até 8 000 caracteres;
  - `Proposals.answer_questions/4` valida, corta cada "Outro" e pede a rodada pelo mesmo caminho do "pedir de novo";
  - o motivo do auto-approve e o comentário de triagem na issue listam as perguntas com as opções e a recomendada, por `Questionnaire.question_text/1` e `to_text/1`.
- **`apps/pipe_maestro_web`:** a página da proposta ganhou o card "Perguntas do agente". O `QuestionnaireLive` ganhou `actions` e `submit_label`, com `task_id` opcional, e as telas de decisão seguem iguais.
- **`apps/pipe_maestro_runner`:** só o dublê de teste `fake_claude` e uma correção no `GateCache`. O cache de gates perdia o horário original do índice do git ao copiá-lo, e um arquivo reescrito no mesmo segundo, com o mesmo tamanho, passava por inalterado. Essa era a causa de uma falha intermitente de teste. A correção não faz parte do escopo, mas era nossa pela regra do projeto.
- **`apps/pipe_maestro_protocol`:** não mudou.

**Protocolo.** Não mudou. O `output_schema` do job é um mapa livre, então um runner antigo repassa o schema maior ao CLI como já faz com as etapas. Um job despachado antes do deploy volta com frases e cai no formato antigo, mostrado como lista.

**Riscos e o que olhar.**
- O texto de cada pergunta não tem limite. Só o "Outro" é cortado (1 500 bytes por resposta). Quatro perguntas muito longas poderiam passar de 8 000 caracteres, e o envio mostraria erro em flash, sem perder nada.
- Duas pessoas respondendo ao mesmo tempo criam duas rodadas, como já acontece no "pedir de novo".
- O comentário de status das decisões de tarefa agora marca "(recomendada)" e usa " — " antes das opções.
- A correção do `GateCache` mexe no runner, e há um teste determinístico que a prova.

**Como verificar.**
- `make ci`: passou (etapa 5).
- `make e2e FILE=tests/agent-proposals.spec.ts` e `make e2e FILE=tests/decision-questionnaire.spec.ts`; a suíte e2e inteira passou na etapa 6.
- Na tela, com o `fake_claude`: peça uma tarefa com "[nao-pronta]" no texto e auto-approve ligado. A proposta mostra o motivo com a pergunta, e o card "Perguntas do agente" abaixo. Escolha uma opção, revise e confirme: a página vai para a nova proposta, que vira a tarefa. Numa proposta já convertida, só a leitura aparece.
- Capturas em claro e escuro: `e2e/screenshots/agent-proposals/` (cópias na plataforma, em `telas/`).

**Documentos atualizados.** ADR 0029 e `docs/specs/integracoes.md`.
