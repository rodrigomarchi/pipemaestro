defmodule ClaudeControlPlane.Pipelines.Templates do
  @moduledoc """
  Ready-made pipelines a workspace starts from: "Prompt único" (the task's
  prompt, as one stage) and "Correção de bug" (the reference stages of the
  product plan: triage, investigation, reproduction, fix, audit, PR).
  """

  @doc "The templates, as attributes for `ClaudeControlPlane.Pipelines.create_pipeline/2`."
  @spec all() :: [map()]
  def all, do: [single_prompt(), bug_fix()]

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
