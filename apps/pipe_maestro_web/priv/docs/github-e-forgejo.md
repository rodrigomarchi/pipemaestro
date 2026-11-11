Com o host git conectado, as issues viram tarefas sozinhas, a issue mostra o andamento e o
PR se corrige a partir do review. Só administradores do workspace configuram integrações.

{{tela:integrations}}

## Conectar

Em **Integrações**, crie uma conexão:

- **GitHub**: salvar leva você ao GitHub para instalar o App da plataforma nos repositórios
  que escolher. A instalação volta confirmada pelo seu login no GitHub.
- **Forgejo**: com o token de uma conta bot (recomendado: as ações aparecem como do bot) ou
  por OAuth, que leva você ao Forgejo para autorizar.

## Vincular um repositório a um projeto

Um repositório da conexão se vincula a um [projeto](/docs/tarefas-e-pipelines#projeto): o
código que a tarefa muda é o do diretório do projeto no runner, e o PR vai para esse
repositório. Ao vincular, a plataforma cria as labels e o webhook. Sem permissão para criar
o webhook, a página mostra o endereço e o segredo para você cadastrar à mão.

## Gatilhos

O gatilho diz que eventos viram tarefa:

| Gatilho | Dispara quando |
|---|---|
| Label | a label (por padrão, `pipemaestro`) é adicionada à issue |
| Comentário | um comentário começa com `/pipemaestro`, numa issue sem tarefa ativa |
| Issue aberta | qualquer issue nova é aberta |

E como:

- **Modo**: *triagem*, em que o agente escreve a tarefa a partir da issue (e pergunta, se
  ela não estiver pronta), ou *tarefa direta*, em que a issue vira a tarefa como está.
- **Aprovação automática** (ligada por padrão): a tarefa da triagem começa sozinha.
- **Pipeline**: o que a tarefa vai usar; na triagem é opcional.
- **Quem pode disparar**: só quem tem escrita no repositório (o padrão), ou qualquer pessoa,
  com triagem e confirmação.
- **Limite por hora** (padrão 10), para uma enxurrada de issues não virar uma enxurrada de
  tarefas.
- **Em nome de quem**: a pessoa do workspace dona das tarefas criadas.

Um gatilho dispara uma vez por issue. Tirar a label e pôr de novo dispara outra vez, se a
issue não tiver tarefa em andamento.

## O que a issue recebe

| Label | Quando |
|---|---|
| `pipemaestro` | o gatilho; a plataforma nunca a remove |
| `pipemaestro:triando` | triagem ou fila |
| `pipemaestro:em-andamento` | executando |
| `pipemaestro:aguardando-decisao` | parada esperando alguém |
| `pipemaestro:pronto` | concluída, PR pronto |
| `pipemaestro:cancelada` | cancelada |

Além das labels, um **comentário de status** editado no lugar, um **status de commit** por
etapa (`pipemaestro/<etapa>`) e, no GitHub, um **check run** por etapa, com "Refazer etapa"
na etapa parada.

## Entregas

Cada webhook recebido fica registrado na página do repositório: o evento, o que a plataforma
fez com ele e, se ignorou, por quê. Uma reconciliação periódica pega o que um webhook
perdido deixou para trás.

Próximo passo: os [comandos na issue e no PR](/docs/comandos).
