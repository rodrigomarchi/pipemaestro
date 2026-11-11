**A situação:** o time vive no GitHub (ou no Forgejo). Você quer que uma issue marcada com
uma label vire uma tarefa e depois um PR, sem copiar nada para a plataforma.

**O que precisa:** uma conexão com o host git e o repositório vinculado a um projeto.
Veja [Conectar o GitHub ou o Forgejo](/docs/github-e-forgejo).

## 1. Alguém põe a label

Na issue, alguém com permissão de escrita no repositório adiciona a label `pipemaestro`.
O host avisa a plataforma por webhook, e o gatilho do repositório decide o que fazer:

- **Triagem** (o padrão): o agente lê a issue e escreve a tarefa, com título, pedido e
  critérios de aceite. Com aprovação automática, ela já começa.
- **Tarefa direta**: a issue vira a tarefa como está, no pipeline do gatilho.

Se a issue não está pronta, a triagem não cria a tarefa e comenta na issue o porquê, com
as perguntas e as opções de cada uma. Respondidas, ela tenta de novo.

## 2. A issue mostra o andamento

Enquanto a tarefa roda, a própria issue conta o que acontece:

- **Um comentário de status**, editado no lugar: o estado, as etapas e os links da tarefa
  e do PR.
- **A label de estado**: `pipemaestro:triando`, `pipemaestro:em-andamento`,
  `pipemaestro:aguardando-decisao`, `pipemaestro:pronto` ou `pipemaestro:cancelada`.
- **Um status por etapa** no commit do PR (`pipemaestro/<etapa>`) e, no GitHub, um check run
  por etapa.

Comentários novos, que notificam, só aparecem quando importa: a tarefa espera uma decisão
(mencionando quem abriu a issue), o PR ficou pronto ou a tarefa foi cancelada.

## 3. Decida sem sair da issue

A tarefa parou com uma pergunta? Responda num comentário:

```text
/pipemaestro responder
1. Separador ponto e vírgula
2. Só administradores do financeiro
```

Ou mande seguir com uma instrução:

```text
/pipemaestro seguir use o fuso de São Paulo nas datas
```

A plataforma reage com 👍 e a tarefa continua. Todos os comandos estão em
[Comandos na issue e no PR](/docs/comandos).

## 4. Revise o PR

O PR abre em rascunho na primeira etapa e fica pronto ao fim. Um review pedindo mudanças
vira uma etapa "Correção" com o texto do review e os comentários de linha. Se o pipeline
estiver com **merge automático**, a plataforma espera o CI do repositório passar e faz o
merge; um check vermelho vira mais uma correção.

{{tela:integrations}}

## Variações

- **Escolher o pipeline no comentário:** com um gatilho de comentário, `/pipemaestro
  Correção de bug` numa issue cria a tarefa naquele pipeline (pelo nome, sem diferenciar
  maiúsculas). Só `/pipemaestro` usa o pipeline do gatilho.
- **Qualquer issue nova:** um gatilho de abertura cria a tarefa (ou a triagem) para toda
  issue aberta, com um limite por hora.
