# Documentação e resumo

## Resumo para quem vai revisar

### O que mudou e por quê
O binário único do runner (Burrito) passa a **se atualizar por padrão** quando a plataforma o recusa por versão (`"outdated"`, no `login` ou em qualquer join). Antes ele perguntava `[S/n]` no terminal, e sem terminal só mostrava a mensagem e saía. `--no-auto-update` desliga e restaura esse comportamento (issue #20).

- **`apps/pipe_maestro_runner`**:
  - `Update.consent/2` só pergunta (ou, sem terminal, recusa com a mensagem) quando `auto_update == false`.
  - `Service` grava `start` sem `--auto-update`.
  - O uso em `Main`, `Commands.Start` e `Commands.Login` mostra `[--no-auto-update]`.
  - `--auto-update` segue aceito, por compatibilidade.
  - `test/test_helper.exs` isola a suíte das variáveis de credencial git do ambiente.
- **`apps/pipe_maestro`, `apps/pipe_maestro_web`, `apps/pipe_maestro_protocol`**: não mudam.
- **E2E/config**:
  - `config/e2e.exs` ganhou o comentário novo de `:update_prompt`.
  - `e2e/helpers/runnerProcess.ts` inicia o runner sem as variáveis de credencial git.
  - O Flow E em `e2e/tests/runner-connection.spec.ts` passa `--no-auto-update` nos dois passos.

### Protocolo
**Não mudou.** O payload `"outdated"` é o mesmo e `protocol_version` não sobe. Runners antigos se comportam como antes até se atualizarem:
- Sem a opção, perguntam.
- Serviços instalados com `start --auto-update` seguem atualizando, sem reinstalar, porque a opção continua aceita.

### Riscos e o que olhar com atenção
- O binário passa a trocar o próprio executável sem confirmação. As garantias são as da ADR 0025: origem única, https, SHA-256 e troca atômica. Quem quer controle manual usa `--no-auto-update`.
- O Flow E precisa de `--no-auto-update` nos dois passos (`login` e `start`). Sem ele, o runner do e2e tentaria baixar de verdade.
- A mudança em `test_helper.exs` e `runnerProcess.ts` é correção de ambiente, sem relação funcional com a tarefa. Rodado por um agente, o runner herdava as variáveis de credencial git e os testes do `JobRunner` falhavam.
- `make ci` completo (com Dialyzer) não foi rodado na etapa de implementação. `consent/2` mantém o mesmo tipo de retorno.

### Como verificar
- `make ci > /tmp/ci.log 2>&1; echo $?`
- `make e2e FILE=e2e/tests/runner-connection.spec.ts` (ou `make e2e` para a suíte inteira)
- `cd apps/pipe_maestro_runner && mix test`
- Manual, com um binário único desatualizado:
  - `pipemaestro start` atualiza e reexecuta sem perguntar.
  - `pipemaestro start --no-auto-update` pergunta `[S/n]` no terminal.
  - Sem terminal, `--no-auto-update` mostra a mensagem e sai.
  - `pipemaestro service install` gera plist/unit com `start` sem `--auto-update`.
- Nenhuma tela mudou: não há screenshots a conferir.

### ADRs e docs
- Nova: `docs/adr/0038-atualizacao-automatica-por-padrao.md`.
- Alterada: `docs/adr/0025-atualizacao-automatica-do-runner.md` (status aponta a 0038).
- `docs/README.md`: índice com as ADRs 0038, e também 0036 e 0037, que estavam faltando, e a nota na 0025.
- `docs/guias/instalacao.md` (seção "Runner desatualizado").
- `docs/specs/protocolo-runner.md` (só o texto do comportamento do runner).
- `docs/plano/03-roadmap-orquestrador.md`.
