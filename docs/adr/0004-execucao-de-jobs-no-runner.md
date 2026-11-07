# 0004 — Execução de jobs no runner

- **Status:** aceita
- **Data:** 03/11/2026

## Contexto

O runner já faz login e se conecta (ADR 0003), mas ainda não executa nada. Antes do
pipeline, da integração com o GitHub e dos containers, queremos ligar as pontas: uma
pessoa manda um prompt pela plataforma, o runner roda o agente na própria máquina e
a execução aparece ao vivo. Isso é o esqueleto do "runtime de etapa" (§5.3 da visão)
e da parte de jobs do protocolo (§5.4).

## Decisões

1. **Job é um prompt enviado a um runner escolhido pela pessoa.** Não há dispatcher
   nem fila no servidor: a tela só oferece runners online, e o job vai direto para o
   canal do runner (`job:assign`). Jobs ainda na fila são reenviados a cada join.
2. **O agente é o `claude` CLI em modo headless**:
   `claude -p <prompt> --output-format stream-json --verbose
   --dangerously-skip-permissions --no-session-persistence`. (Uma etapa que continua a
   anterior guarda e retoma a sessão: [ADR 0041](0041-continuar-a-sessao-da-etapa-anterior.md).)
   Ele roda num `Port`, com
   stdin em `/dev/null`, porque o CLI lê o stdin em pipe como parte do prompt. As
   variáveis de sessão aninhada (`CLAUDECODE`) também são removidas, assim como a
   `__BURRITO` do binário único: com ela, uma VM Elixir que o agente inicie e que
   carregue o app do runner subiria como o CLI do runner. `$CLAUDE_BIN`
   troca o executável, e os testes usam um fake.
3. **Workdir único e fixo**, `<config_dir>/workdir`, ao lado das credenciais. Todos os
   jobs rodam nele. É a premissa de "ambiente quente": clone, dependências e build
   ficam ali para a próxima execução. Para que dois jobs não pisem um no outro, o
   runner executa **um job por vez** e os demais esperam numa fila local.
4. **Permissões totais, sem container. Este é um risco aceito**, permanente para as
   etapas ([ADR 0018](0018-etapas-autonomas.md)) até a fase de containers. Qualquer
   membro do workspace consegue rodar comandos arbitrários na máquina do runner. O
   `runner.start` avisa isso ao subir. A fase de containers (§4.3 da visão) substitui
   esta decisão, com permissões negativas no repositório e rede restrita.
5. **O runner resume o `stream-json`.** As linhas do CLI são grandes e, na maior
   parte, internas: metadados da sessão, contadores de tokens, assinaturas. O runner
   reduz cada linha a eventos pequenos (`PipeMaestroProtocol.JobEvent`: sessão,
   texto do agente, chamada e resultado de ferramenta, fim), com o texto cortado em
   8 KB. O formato desses eventos é contrato e fica no app `protocol`.
6. **Eventos numerados e idempotentes.** Cada evento leva um `seq`, e o par
   `(job_id, seq)` é único no banco, então um reenvio é ignorado. Se a conexão cair no
   meio do job, os eventos desse intervalo se perdem, e a lacuna de `seq` fica
   visível. O job continua rodando.
7. **Reconciliação no join.** O `Hello` passa a carregar `running_job_ids`. Um job
   `running` desse runner que não aparece na lista perdeu o processo (o runner
   reiniciou) e é marcado como `failed`.
8. **Cancelar mata o grupo de processos.** O processo do `Port` lidera a própria
   sessão, e tudo o que o agente inicia entra nesse grupo. O runner envia SIGTERM ao
   grupo e, se em 5 s ele ainda existir, SIGKILL. Um filho órfão manteria o pipe do
   `Port` aberto, e o job nunca terminaria.
9. **O protocolo passa à v2.** A v1 nunca foi distribuída, então nenhuma janela de
   compatibilidade foi aberta.

## Fora deste passo

- Container por etapa, permissões restritas e rede limitada.
- Workdir com git (clone bare e worktree por tarefa).
- Pipeline com etapas, GitHub e PR.
- Dispatcher, leases e reatribuição.
- Buffer de eventos durante uma desconexão.
