Este guia leva você do workspace vazio ao primeiro Pull Request. São cinco passos, e
nenhum deles pede para abrir uma porta na sua rede ou mandar o seu código para fora da
sua máquina.

## O que você precisa

- Um **workspace** na plataforma e um usuário nele (quem administra a plataforma cria os
  dois e envia o acesso).
- Uma máquina com o seu código: o seu notebook, um servidor do time ou uma VM.
- O **Claude Code** instalado e com login feito nessa máquina. O agente roda com a sua
  conta, então os limites e a cobrança do Claude são os seus.

Os passos 1 a 3 (runner, projeto e pipeline) são de um **administrador** do workspace. Criar
e acompanhar tarefas, qualquer membro pode.

## 1. Conecte uma máquina como runner

O runner é um executável que roda o agente perto do seu código. Em **Executores**, clique em
**Conectar runner**, baixe o executável do seu sistema e entre:

```bash
pipemaestro login --url https://app.pipemaestro.dev
```

O terminal mostra um código de oito letras. Confirme o código no navegador e dê um nome à
máquina.

{{tela:setup-runner}}

Depois ligue o runner apontando para a pasta onde ficam os seus repositórios:

```bash
pipemaestro start --root ~/src
```

Em segundos ele aparece **online** na página de Executores. Os detalhes (serviço, várias
máquinas, diagnóstico) estão em [O runner na sua máquina](/docs/runner).

{{tela:runners}}

## 2. Cadastre o projeto

Um projeto é um diretório do runner com os comandos que provam que o código está bom. Em
**Projetos**, clique em **Novo projeto**, escolha o runner e um dos diretórios que ele
oferece e preencha:

| Campo | Exemplo | Para quê |
|---|---|---|
| Setup | `make deps` | prepara o worktree de cada tarefa |
| Teste | `make test` | o gate que decide se uma etapa passou |
| Lint | `make lint` | o segundo gate, quando existe |
| Notas para os agentes | "Postgres na porta 5432; nunca edite `priv/legacy`" | contexto que entra no prompt |

{{tela:setup-project}}

Não sabe os comandos de cor? Clique em **Analisar com IA**: o agente estuda o diretório numa
cópia descartável e devolve o formulário preenchido. Nada é salvo até você salvar.

## 3. Escolha um pipeline

Em **Pipelines**, clique em **Criar pipelines padrão**. Você ganha pipelines prontos, que
pode usar como estão ou editar:

| Pipeline | Etapas |
|---|---|
| Correção de bug | Triagem → Investigação → Reprodução com teste → Implementação → Validação e auditoria → PR pronto |
| Nova funcionalidade | Especificação → Plano → Implementação → Revisão de código e Revisão de segurança, em paralelo |
| Refatoração | Mapa → Refatoração → Verificação |
| Atualização de dependência | Changelog → Atualização → Risco |
| Investigação de produção | Hipóteses → Conclusão (não altera o código) |
| Revisão de código | Revisão (não altera o código) |
| Prompt único | Executar |

{{tela:setup-pipelines}}

Para um comando do projeto decidir se uma etapa passou, edite o pipeline, abra a etapa e, na
aba **Verificação**, ponha o gate: `{{projeto.teste}}` roda o comando de teste do projeto
depois do agente, e a etapa só segue se ele passar.

{{tela:setup-gate}}

Para o código virar um PR, edite o pipeline e, em **Entrega (num diretório com git)**,
escolha a entrega em pull request. O diretório do projeto precisa de um `origin` no GitHub
ou num Forgejo: o runner envia o branch e abre o PR com as credenciais da máquina (no
GitHub, pelo `gh` autenticado).

## 4. Crie a primeira tarefa

Clique em **Nova tarefa**, escreva o pedido como escreveria para uma pessoa do time e
escolha o pipeline e o projeto:

> **Corrigir arredondamento do total com cupom**
>
> Pedidos com cupom de 10% mostram R$ 189,91 no checkout e R$ 189,90 na fatura. O total
> deve bater nos dois lugares.

{{tela:first-task-new}}

Prefere só descrever a ideia? Em **Tarefas**, **Escrever com IA** transforma algumas frases
numa tarefa completa, com critérios de aceite.

## 5. Acompanhe e revise o PR

A tarefa aparece no board e cada etapa roda num worktree próprio do runner, com o próprio
branch. Você vê o agente trabalhando ao vivo, o artefato que cada etapa escreve e os
arquivos que ela mudou.

{{tela:first-task-stage}}

Se um gate falha, a etapa tenta de novo, até o limite de tentativas dela. A saída do comando
fica na verificação da tentativa:

{{tela:first-task-gate}}

Se o agente precisar de você, a tarefa pausa e o sino avisa (veja
[Decisões](/docs/decisoes)). Quando a última etapa passa, o PR sai do rascunho e fica
pronto para a sua revisão.

## Próximos passos

- Veja [exemplos do dia a dia](/docs#exemplos) para escolher o pipeline certo para cada
  pedido.
- Conecte o [GitHub ou o Forgejo](/docs/github-e-forgejo) e deixe as issues virarem
  tarefas sozinhas.
