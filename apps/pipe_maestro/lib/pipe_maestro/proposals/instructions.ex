defmodule PipeMaestro.Proposals.Instructions do
  @moduledoc """
  What the agent of a proposal is told: the system prompt that explains how a
  PipeMaestro pipeline works and how to study the project, and the prompt
  with the person's request (and, on a new round, the last proposal and their
  comment).
  """

  alias PipeMaestro.Pipelines
  alias PipeMaestro.Pipelines.{Prompt, Templates, Yaml}

  # The prompt carries the last proposal on a new round; past this it is cut,
  # so the job stays under the wire's limit (PipeMaestroProtocol.Job).
  @previous_bytes 16_000

  @doc "The system prompt, appended to the agent's own."
  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    # Você está propondo um pipeline do PipeMaestro

    O PipeMaestro leva uma tarefa de engenharia por um pipeline de etapas. Cada etapa é um
    agente como você, rodando com todas as permissões num worktree git da tarefa, uma depois
    da outra (ou em paralelo, quando estão no mesmo grupo). Ao fim, a entrega é um commit ou
    um pull request para uma pessoa revisar.

    Você está num **worktree descartável** do projeto, apagado quando você terminar: leia,
    instale, compile e rode o que precisar; nada do que fizer aqui chega ao projeto.

    ## Estude o projeto primeiro

    1. Leia o README, os manifestos (mix.exs, package.json, pyproject.toml, go.mod,
       Cargo.toml...), o Makefile, a configuração de CI e os guias para agentes
       (AGENTS.md, CLAUDE.md).
    2. Descubra como o projeto instala as dependências, compila, roda, testa e faz lint.
    3. **Rode** os comandos de teste e de lint que vai propor e registre em `verificacoes`
       se passaram. Se um precisar de serviço externo (banco, docker), diga isso em
       `observacao` em vez de inventar.

    ## O projeto (campo `projeto`)

    A configuração do diretório, que as etapas recebem por variáveis:

    - `setup`: o comando que prepara um checkout novo (instalar dependências, compilar);
    - `teste` e `lint`: os comandos que provam que uma mudança está boa;
    - `copy_paths`: pastas de dependências e build que valem copiar para cada worktree
      (deps, _build, node_modules...), em vez de reinstalar;
    - `notas`: em Markdown, o que todo agente do pipeline precisa saber do projeto
      (arquitetura, convenções, armadilhas, o portão de qualidade).

    ## O pipeline (campo `pipeline`)

    - `name` (curto) e `description`;
    - `delivery`: `pr` (abre um pull request, o comum), `commit` ou `none`;
    - `system_prompt`: opcional, vale para todas as etapas;
    - `stages`: de 1 a 20 etapas, cada uma com:
      - `key`: minúsculas, dígitos, `-` ou `_` (ex.: `plano`); `name`; `prompt`;
      - `prompt`: o que o agente da etapa faz, em Markdown. Pode usar só estas variáveis:
        #{Enum.map_join(Prompt.variables(), ", ", &"`{{#{&1}}}`")}.
        `{{artefatos}}` traz o que as etapas anteriores escreveram;
      - `gates`: comandos que o runner roda depois do agente, que precisam passar (exit 0);
        um `!` na frente quer dizer que precisa falhar. Podem usar as variáveis `projeto.*`
        (ex.: `{{projeto.teste}}`);
      - `rules`: quando pausar a tarefa para uma pessoa, a partir da saída da etapa
        (`status == bloqueado`). A saída de toda etapa já tem `status` (`ok` ou
        `bloqueado`) e `resumo`;
      - `max_attempts` (1 a 5), `model` (#{Enum.join(Pipelines.Stage.models(), ", ")}),
        `timeout_minutes`;
      - `group`: etapas seguidas com o mesmo grupo rodam ao mesmo tempo (ex.: revisões).

    As etapas seguem sozinhas: só uma regra, uma falha ou o orçamento param a tarefa. Faça
    etapas que se apoiem nos comandos reais do projeto, com gates de teste e lint onde a
    etapa muda código, e prompts específicos deste projeto, não genéricos.

    ## Exemplo de pipeline

    ```yaml
    #{example()}
    ```

    ## Sua resposta

    Responda no formato pedido: `analise` (Markdown: o que o projeto é e como funciona),
    `verificacoes`, `projeto` e `pipeline`. Escreva em português.
    """
  end

  @doc """
  The agent's prompt: the person's `request` about `directory`, and, on a new
  round, the last proposal (`previous`, its structured output) with their
  `feedback`.
  """
  @spec prompt(String.t(), String.t(), map() | nil, String.t() | nil) :: String.t()
  def prompt(request, directory, previous \\ nil, feedback \\ nil) do
    [
      """
      Analise o projeto do diretório `#{directory}` e proponha a configuração do projeto e um
      pipeline do PipeMaestro para o pedido abaixo.

      #{request}
      """,
      previous_section(previous),
      feedback_section(feedback)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp previous_section(%{} = previous) when map_size(previous) > 0 do
    """
    ## Sua proposta anterior

    ```json
    #{previous |> JSON.encode!() |> String.slice(0, @previous_bytes)}
    ```
    """
  end

  defp previous_section(_none), do: nil

  defp feedback_section(feedback) when is_binary(feedback) and feedback != "" do
    """
    ## O que a pessoa pediu para ajustar

    #{feedback}

    Refaça a proposta com esse ajuste, mantendo o que estava bom.
    """
  end

  defp feedback_section(_none), do: nil

  defp example do
    template = Enum.find(Templates.all(), &(&1["name"] == "Nova funcionalidade"))

    %Pipelines.Pipeline{}
    |> Pipelines.change_pipeline(Map.merge(template, %{"delivery" => "pr"}))
    |> Ecto.Changeset.apply_changes()
    |> Yaml.to_yaml()
    |> String.trim_trailing()
  end
end
