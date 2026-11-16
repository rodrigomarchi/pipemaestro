# 0058 — Cadastro aberto e plano Free beta

- **Status:** aceita
- **Data:** 16/11/2026
- **Relacionadas:** [ADR 0002](0002-identidades-e-workspaces.md), [ADR 0054](0054-retencao-por-workspace.md), [ADR 0057](0057-documentacao-publica.md)

## Contexto

Até aqui só um operador criava usuário e workspace, no backoffice (ADR 0002: "não há
auto-cadastro"). A landing convidava a "começar agora" e levava a um login que quem
chegava não tinha como usar. Para o beta, qualquer pessoa precisa poder criar a conta e o
workspace sozinha, de graça, e aprender a colocar o primeiro pipeline de pé.

## Decisões

1. **Cadastro aberto, com cara de checkout.** A landing leva a `/pricing`, que mostra um
   único card, o plano **Free** com o selo **BETA**. "Começar grátis" leva a `/signup`
   (nome, e-mail e senha), que cria a conta e já entra. Sem workspace, a pessoa vai para
   `/workspaces/new`, dá nome e endereço ao workspace e vira a admin dele.
2. **Sem e-mail no beta.** Não há confirmação de e-mail nem recuperação de senha por
   e-mail. Quem esquece a senha fala com o suporte, e o operador a redefine no backoffice,
   como já fazia. As regras de senha continuam as de `Auth.Credentials`. Também não há
   aceite de termos nem login com GitHub.
3. **O plano é um campo do workspace.** `plan` é `:custom` (criado pelo operador, com os
   limites que ele escolher) ou `:free_beta` (criado pelo cadastro). `owner_id` guarda
   quem o criou. Os limites do Free ficam num lugar só, `Workspaces.Plan`, que o domínio
   aplica e a página de planos mostra: 3 workspaces por dono, 2 tarefas ao mesmo tempo,
   500 MiB de anexos, anexos e eventos do agente mantidos por 14 dias e log do runner por
   7. Quem cria o workspace só escolhe o nome e o endereço (`Workspace.owned_changeset/2`).
   A contagem de workspaces por dono trava a linha do usuário, para que duas criações ao
   mesmo tempo não passem do limite.
4. **Rate limit no login e no cadastro.** Sem confirmação de e-mail, ele é a defesa contra
   robôs: 10 tentativas de login a cada 15 minutos por endereço IP e por e-mail, e 5
   cadastros por hora por IP. Usa o contador em ETS que já protegia o login do runner
   (`PipeMaestroWeb.RateLimit`), com os limites na configuração. Cada nó conta os seus.
5. **Uma aula de primeiros passos, não um assistente.** No primeiro acesso a um workspace
   Free que ainda não tem runner, projeto e pipeline, a admin vê uma aula em tela cheia,
   em três passos: conectar o runner, cadastrar o projeto e escolher o pipeline. A aula
   só mostra como se faz, com os mesmos textos, comandos e telas da landing
   (`LandingShots.walkthrough/0`); nada é configurado por ela. Concluir ou pular é
   definitivo para aquela pessoa naquele workspace (`onboarding_seen_at` do vínculo).
   Workspaces `:custom` nunca mostram a aula: o operador acompanha esses clientes.

## Consequências

- A ADR 0002 fica superada no ponto do auto-cadastro. O backoffice continua criando
  workspaces e usuários como antes.
- Um usuário criado pelo operador sem workspace passa a ser levado a criar o próprio, no
  plano Free.
- Os workspaces que já existiam ficam `:custom` e não mudam de comportamento.

## Fora deste passo

- Envio de e-mail: confirmação, recuperação de senha e convites.
- Termos de uso e política de privacidade.
- Login com GitHub.
- Planos pagos e cobrança.
- Gestão de membros pela admin do workspace.
