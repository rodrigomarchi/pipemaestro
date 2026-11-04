# 0016 — Linha do tempo compacta: faixas de ícones e painéis

- **Status:** aceita
- **Data:** 04/11/2026

## Contexto

A linha do tempo de um job ([ADR 0007](0007-visualizacao-da-tarefa.md),
[ADR 0014](0014-pendencias-do-roadmap.md), [ADR 0015](0015-auditoria-da-execucao.md))
desenhava cada evento numa linha inteira: ícone, rótulo e corpo. Com a auditoria, os
eventos sem texto para ler cresceram (sessão, pensamento, chamadas e resultados de
ferramenta, limites, retries, compactações, negações) e passaram a ocupar a maior parte
da tela, empurrando para baixo o que a pessoa de fato lê: as respostas do agente e o
resultado. O agrupamento "Leu 3 arquivos e fez 1 busca" do ADR 0014 só resolvia leituras
e buscas.

A linha do tempo aparece em três lugares: a página do job e a etapa rodando da tarefa,
as duas ao vivo e com stream do LiveView, e o passo a passo de uma tentativa terminada,
com filtros.

## Decisões

1. **Dois tipos de segmento.**
   - **Bloco de texto:** `assistant_text` e `result`, em largura total, como antes.
   - **Faixa de ícones:** todo o resto, inclusive um tipo desconhecido (ícone genérico,
     rotulado pelo próprio tipo). Ícones seguidos ficam lado a lado numa faixa que
     quebra de linha quando enche; um bloco de texto encerra a faixa.
   - Cada ícone é um `<.icon_button>` do Petal com tooltip (o resumo de uma linha:
     comando, caminho, padrão, linhas da saída, duração do pensamento, janelas dos
     limites, tokens do turno, subagente), `aria-label` e cor por estado: `normal` em
     cinza, `error` (`is_error`, `api_retry`) e `denied` (`permission_denied`, decisão
     `reject`) em vermelho, distinguidos pelo glifo e pelo texto. Um ícone de subagente
     tem contorno tracejado.
2. **O painel abre no cliente, com `Phoenix.LiveView.JS`.**
   - Clicar num ícone mostra, abaixo da faixa, o painel com o conteúdo completo de antes
     (cabeçalho e corpo do evento). Clicar de novo fecha; clicar em outro ícone da mesma
     linha do tempo troca.
   - Os painéis de todos os ícones vêm renderizados e escondidos dentro da faixa; os
     seletores do `JS` são escopados pelo id da linha do tempo, então duas linhas do
     tempo na mesma página não interferem.
   - Não há estado na LiveView: a página do job e a etapa ao vivo usam stream, e o
     servidor não guarda os eventos já enviados. Abrir um painel de uma faixa antiga
     exigiria reler eventos ou guardá-los todos no processo.
   - Erros e negações não abrem sozinhos: ficam como ícone vermelho e abrem no clique.
3. **O stream é de segmentos, e o servidor guarda só a cauda.**
   - A regra de onde vai cada evento é uma função pura, `JobComponents.timeline_push/2`:
     um ícone com faixa aberta entra nela, que mantém o id; um ícone depois de texto abre
     uma faixa nova; um texto vira bloco e fecha a faixa; um `seq` já mostrado é
     descartado (a janela entre a assinatura e a leitura no mount).
   - `timeline_items/2`, usada no mount e no passo a passo, é o `reduce` dessa mesma
     função, aplicado depois do filtro.
   - A faixa que cresce volta por `stream_insert` com o mesmo id. As operações de `JS`
     são sticky, então o painel aberto continua aberto quando a faixa recebe o patch.
4. **Filtros antes das faixas.** Os filtros do passo a passo (Tudo, Agente, Ferramentas,
   Raciocínio, Erros) se aplicam antes do agrupamento. O filtro entra no id da faixa, e
   trocá-lo fecha o painel aberto.
5. **O agrupamento de leituras do ADR 0014 sai.** A faixa já junta leituras e buscas
   seguidas, e o resumo de cada uma fica no tooltip.

## Consequências

- **O ExUnit não executa `JS`.** Ele prova que ícones e painéis existem, que o painel
  começa escondido e que o clique aponta para o painel certo. Abrir, fechar, trocar e o
  painel que continua aberto ao vivo são provados no e2e; o CLI falso de teste do runner
  ganhou o marcador `[gotejando]` para isso.
- **A faixa aberta é reenviada inteira a cada ícone novo.** O item de um stream não é
  diffado, e a faixa leva os painéis com as saídas das ferramentas. Numa etapa longa sem
  texto do agente, o tráfego cresce com o quadrado da faixa, e a cauda guarda os eventos
  dela na memória do processo. O custo foi aceito por ora. Se aparecer, a correção é
  limitar a faixa em `timeline_push/2` (depois de um número de ícones, abrir outra), uma
  regra pura e testável que não afeta o painel aberto numa faixa já fechada.
- **Painel longe do ícone** numa faixa de muitas linhas: o painel vem abaixo da faixa
  inteira; o anel no ícone aberto liga os dois.
- **A saída de erro deixa de vir aberta** e o resumo "Leu N arquivos" some da tela.
- **Testes por `seq`:** ícone, painel, faixa e bloco têm `data-testid` com o `seq` do
  evento (`job-event-icon-<seq>`, `job-event-panel-<seq>`, `job-event-strip-<seq>`,
  `job-event-<seq>`). O `seq` é por job, então testes e specs escopam pelo contêiner da
  linha do tempo.
- Nada muda no protocolo, no domínio nem no banco.
