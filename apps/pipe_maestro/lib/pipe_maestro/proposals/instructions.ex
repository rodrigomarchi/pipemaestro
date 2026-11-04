defmodule PipeMaestro.Proposals.Instructions do
  @moduledoc """
  The parts of a proposal's prompts that the kinds share: how a PipeMaestro
  pipeline works, how to study a project, and how a new round revises the
  last proposal with the person's comment.
  """

  alias PipeMaestro.Pipelines
  alias PipeMaestro.Pipelines.{Prompt, Templates, Yaml}

  # Pieces of data the prompt carries are cut, so the job stays under the
  # wire's limit (PipeMaestroProtocol.Job).
  @previous_bytes 8_000

  @doc "How a pipeline works and what each field means, with an example."
  @spec pipeline_format() :: String.t()
  def pipeline_format do
    """
    ## Como um pipeline do PipeMaestro funciona

    O PipeMaestro leva uma tarefa de engenharia por um pipeline de etapas. Cada etapa é um
    agente rodando com todas as permissões num worktree git da tarefa, uma depois da outra
    (ou em paralelo, quando estão no mesmo grupo). Ao fim, a entrega é um commit ou um pull
    request para uma pessoa revisar.

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

    As etapas seguem sozinhas: só uma regra ou uma falha param a tarefa. Boas
    etapas se apoiam nos comandos reais do projeto, com gates de teste e lint onde mudam
    código, e prompts específicos do projeto, não genéricos.

    O projeto de um diretório dá às etapas, por variáveis: `setup` (prepara um checkout
    novo), `teste` e `lint` (provam que uma mudança está boa), as pastas a copiar para cada
    worktree e `notas` (o que todo agente precisa saber do projeto).

    ### Exemplo

    ```yaml
    #{example()}
    ```
    """
  end

  @doc "How to study the project before answering."
  @spec study_project() :: String.t()
  def study_project do
    """
    ## Estude o projeto primeiro

    Você está num **worktree descartável** do projeto, apagado quando você terminar: leia,
    instale, compile e rode o que precisar dentro dele. O `.git` é compartilhado com o
    projeto: não faça commit, não crie branches, não mude a configuração nem os hooks do
    git, e não escreva fora do worktree.

    1. Leia o README, os manifestos (mix.exs, package.json, pyproject.toml, go.mod,
       Cargo.toml...), o Makefile, a configuração de CI e os guias para agentes
       (AGENTS.md, CLAUDE.md).
    2. Descubra como o projeto instala as dependências, compila, roda, testa e faz lint.
    3. Confira no código o que for afirmar: cite arquivos e módulos reais.
    """
  end

  @doc """
  The sections that revise a proposal: the last one (`previous`, its
  structured output) and what the person asked to change (`feedback`).
  Empty without either.
  """
  @spec revision(map() | nil, String.t() | nil) :: String.t()
  def revision(previous, feedback) do
    [previous_section(previous), feedback_section(feedback)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp previous_section(%{} = previous) when map_size(previous) > 0 do
    """
    ## Sua proposta anterior

    ```json
    #{previous |> JSON.encode!() |> cut(@previous_bytes)}
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

  @doc "`text` cut to `bytes`, on a character boundary, marked when cut."
  @spec cut(String.t() | nil, pos_integer()) :: String.t()
  def cut(nil, _bytes), do: ""

  def cut(text, bytes) when byte_size(text) <= bytes, do: text

  def cut(text, bytes) do
    kept = text |> binary_part(0, bytes) |> String.chunk(:valid) |> List.first("")
    kept <> "\n[…cortado]"
  end

  defp example do
    template = Enum.find(Templates.all(), &(&1["name"] == "Nova funcionalidade"))

    %Pipelines.Pipeline{}
    |> Pipelines.change_pipeline(Map.merge(template, %{"delivery" => "pr"}))
    |> Ecto.Changeset.apply_changes()
    |> Yaml.to_yaml()
    |> String.trim_trailing()
  end
end
