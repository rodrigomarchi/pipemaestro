defmodule PipeMaestro.Pipelines.Templates do
  @moduledoc """
  Ready-made pipelines a workspace starts from: "Prompt único" (the task's
  prompt, as one stage), "Correção de bug" (the reference stages of the
  product plan: triage, investigation, reproduction, fix, audit, PR),
  "Nova funcionalidade", "Refatoração", "Revisão de código", "Investigação de
  produção" (reads only) and "Atualização de dependência". Every stage runs
  with every permission and passes on by itself; the prompts say which ones
  must not change code.
  """

  @doc "The templates, as attributes for `PipeMaestro.Pipelines.create_pipeline/2`."
  @spec all() :: [map()]
  def all,
    do: [
      single_prompt(),
      bug_fix(),
      feature(),
      refactor(),
      code_review(),
      production_investigation(),
      dependency_update()
    ]

  defp stage(key, name, prompt, extra \\ %{}),
    do: Map.merge(%{"key" => key, "name" => name, "prompt" => prompt}, extra)

  defp feature do
    %{
      "name" => "Nova funcionalidade",
      "description" =>
        "Especificação, plano, implementação com testes e revisões de código e de segurança em paralelo.",
      "stages" => [
        stage(
          "especificacao",
          "Especificação",
          """
          Transforme o pedido abaixo numa especificação curta: o que muda para quem usa, os casos
          de borda e os critérios de aceite. Explore o código só para entender onde a mudança cabe.

          {{tarefa.descricao}}

          {{projeto.notas}}

          Se o pedido for ambíguo a ponto de mudar a solução, termine como "bloqueado" e faça
          as perguntas em "perguntas", cada uma com as alternativas, a recomendada primeiro.
          """
        ),
        stage(
          "plano",
          "Plano",
          """
          Com a especificação, escreva o plano de implementação: arquivos a criar ou mudar, a ordem,
          os testes que provam cada critério de aceite e os riscos. Não altere código.
          """
        ),
        stage("implementacao", "Implementação", """
        Implemente o plano, com os testes que ele pede. Rode {{projeto.teste}} e {{projeto.lint}}
        até passarem. No artefato, liste o que mudou e como verificar.
        """),
        stage(
          "revisao",
          "Revisão de código",
          """
          Revise a implementação como um revisor exigente que não a escreveu: o diff contra a
          especificação, testes faltando, nomes, casos de borda. Liste os problemas por
          severidade. Se houver algum grave, termine como "bloqueado".
          """,
          %{"group" => "revisoes"}
        ),
        stage(
          "seguranca",
          "Revisão de segurança",
          """
          Revise só a segurança da implementação, em paralelo à revisão de código: entradas não
          validadas, permissões, segredos, injeções, dados sensíveis em logs. Se houver algum risco
          grave, termine como "bloqueado".
          """,
          %{"group" => "revisoes"}
        )
      ]
    }
  end

  defp refactor do
    %{
      "name" => "Refatoração",
      "description" =>
        "Mapa do código, refatoração em passos com a suíte verde e verificação de comportamento.",
      "stages" => [
        stage(
          "mapa",
          "Mapa",
          """
          Mapeie o código envolvido nesta refatoração: quem chama, o que é coberto por testes e o que
          não é. Proponha os passos, cada um pequeno e com a suíte verde ao fim.

          {{tarefa.descricao}}
          """
        ),
        stage("refatoracao", "Refatoração", """
        Faça a refatoração nos passos do mapa, sem mudar comportamento. Se faltar teste para algo
        que vai mudar de lugar, escreva o teste antes. Rode {{projeto.teste}} a cada passo.
        """),
        stage(
          "verificacao",
          "Verificação",
          """
          Confirme que o comportamento não mudou: compare o diff com o mapa, procure mudanças de
          semântica escondidas e rode {{projeto.teste}}. Registre o que verificou.
          """
        )
      ]
    }
  end

  defp code_review do
    %{
      "name" => "Revisão de código",
      "description" =>
        "Revisa as mudanças do diretório (branch atual contra a principal) sem alterar nada.",
      "stages" => [
        stage(
          "revisao",
          "Revisão",
          """
          Revise as mudanças deste repositório: o que está no branch atual e ainda não está no
          principal, e o que não foi commitado. Foco do pedido:

          {{tarefa.descricao}}

          Liste os problemas por severidade (bloqueia, deveria mudar, sugestão), cada um com arquivo,
          linha e o porquê. Não altere código.
          """
        )
      ]
    }
  end

  defp production_investigation do
    %{
      "name" => "Investigação de produção",
      "description" =>
        "Investiga um problema de produção (logs, métricas, código) e propõe a correção, sem alterar nada.",
      "stages" => [
        stage(
          "hipoteses",
          "Hipóteses",
          """
          Um problema em produção:

          {{tarefa.descricao}}

          Leia o código envolvido e, se houver ferramentas de observabilidade disponíveis (servidores
          MCP), consulte logs e métricas do período. Liste as hipóteses com as evidências a favor e
          contra cada uma.
          """
        ),
        stage(
          "conclusao",
          "Conclusão",
          """
          Feche a investigação: a causa mais provável, o impacto, a correção proposta (sem aplicar) e
          como confirmar em produção. Se as evidências não bastarem, termine como "bloqueado" dizendo
          o que falta medir.
          """
        )
      ]
    }
  end

  defp dependency_update do
    %{
      "name" => "Atualização de dependência",
      "description" => "Lê o changelog, atualiza, corrige o que quebrou e resume o risco.",
      "stages" => [
        stage(
          "changelog",
          "Changelog",
          """
          A dependência a atualizar e a versão alvo:

          {{tarefa.descricao}}

          Leia o changelog entre a versão atual e a alvo e liste as mudanças que afetam este projeto,
          com os pontos do código que usam o que mudou.
          """
        ),
        stage("atualizacao", "Atualização", """
        Atualize a dependência, ajuste o código ao que mudou e rode {{projeto.setup}},
        {{projeto.teste}} e {{projeto.lint}} até passarem.
        """),
        stage(
          "risco",
          "Risco",
          """
          Resuma o risco da atualização para quem vai revisar: o que mudou de comportamento, o que os
          testes cobrem e o que vale testar à mão.
          """
        )
      ]
    }
  end

  defp single_prompt do
    %{
      "name" => "Prompt único",
      "description" => "Executa o prompt da tarefa numa única etapa.",
      "stages" => [
        %{
          "key" => "executar",
          "name" => "Executar",
          "max_attempts" => 1,
          "prompt" => """
          {{tarefa.descricao}}

          Registre no artefato o que foi feito e o que ficou pendente.
          """
        }
      ]
    }
  end

  defp bug_fix do
    %{
      "name" => "Correção de bug",
      "description" =>
        "Triagem, investigação, reprodução com teste, correção, auditoria independente e preparação do PR.",
      "stages" => [
        %{
          "key" => "triagem",
          "name" => "Triagem",
          "prompt" => """
          Avalie se esta tarefa está bem definida o bastante para ser corrigida sem perguntas:

          {{tarefa.descricao}}

          Explore o repositório só o necessário para localizar a área afetada. No artefato, registre:
          o problema com suas palavras, a área do código provavelmente envolvida, o comportamento
          esperado e os critérios de pronto. Se faltar informação essencial, termine como "bloqueado"
          dizendo exatamente o que falta. Não altere código nesta etapa.
          """
        },
        %{
          "key" => "investigacao",
          "name" => "Investigação",
          "prompt" => """
          Encontre a causa raiz do problema descrito na triagem. Leia o código envolvido, siga o fluxo
          e formule a hipótese mais provável, com os arquivos e linhas que a sustentam. Registre no
          artefato a causa raiz, as evidências e o plano de correção. Não altere código nesta etapa.
          """
        },
        %{
          "key" => "reproducao",
          "name" => "Reprodução com teste",
          "prompt" => """
          Escreva um teste automatizado que reproduz o problema, seguindo as convenções de testes do
          projeto (veja CLAUDE.md/AGENTS.md). Rode-o e confirme que ele FALHA pelo motivo certo.
          Registre no artefato o arquivo do teste, o comando para rodá-lo e a saída da falha.
          Não corrija o problema nesta etapa.
          """
        },
        %{
          "key" => "implementacao",
          "name" => "Implementação",
          "max_attempts" => 3,
          "prompt" => """
          Corrija o problema seguindo o plano da investigação. Faça a menor mudança que resolve a
          causa raiz, sem refatorações fora do escopo. Rode o teste da etapa de reprodução (agora deve
          passar) e a suíte relevante do projeto. Registre no artefato os arquivos alterados, o porquê
          de cada mudança e a saída dos testes.
          """
        },
        %{
          "key" => "auditoria",
          "name" => "Validação e auditoria",
          "prompt" => """
          Revise a correção como um revisor independente: você não fez a implementação. Leia o diff,
          os artefatos anteriores e rode as verificações do projeto (testes, lint). Procure regressões,
          casos de borda e desvios do escopo. Registre no artefato os achados; se houver problema
          grave, termine como "bloqueado" explicando o que precisa mudar.
          """
        },
        %{
          "key" => "pr",
          "name" => "PR pronto",
          "prompt" => """
          Prepare a entrega: escreva no artefato o título e a descrição do pull request (contexto,
          causa raiz, correção, como testar), resumindo os artefatos anteriores. Se o projeto e a
          tarefa pedirem, faça os commits; não faça push nem abra PR a não ser que a tarefa peça.
          """
        }
      ]
    }
  end
end
