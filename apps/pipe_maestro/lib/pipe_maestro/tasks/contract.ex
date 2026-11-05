defmodule PipeMaestro.Tasks.Contract do
  @moduledoc """
  The contract between the platform and the agent of a task's stage, in one
  place (ADR 0033): which checks the runner makes after the agent
  (`PipeMaestroProtocol.Job` `checks`), how the agent is told about them in
  its prompt, and how they read on screen.

  The agent does the work in git (it commits); the platform verifies, and only
  pushes and writes its own block of the pull request. The contract applies to
  a stage that delivers: a task in a git worktree, with a pipeline whose
  delivery is `commit` or `pr`, in a stage that does not run in a group (the
  stages of a group share the worktree at once, so none of them can be held
  to it).

  The task's artifacts live in `.control-plane/<task>/` in the worktree: each
  stage commits its own, so the pull request shows the work as it goes and
  another agent can go on from the branch; the last stage takes the folder out
  of the branch, keeping it on disk. The control plane keeps every artifact.
  """

  alias PipeMaestro.Pipelines.{Prompt, Stage}

  @typedoc "Where a stage is in its task."
  @type place :: %{
          required(:task_id) => String.t(),
          required(:branch) => String.t(),
          required(:index) => non_neg_integer(),
          required(:last?) => boolean(),
          required(:pr?) => boolean()
        }

  @last_stage "Esta é a última etapa da tarefa"

  @doc "The folder of a task's artifacts, relative to its worktree."
  @spec artifacts_dir(String.t()) :: String.t()
  def artifacts_dir(task_id), do: Path.dirname(Prompt.artifact_path(task_id, 0, "x"))

  @doc "The checks the runner makes after the agent of `stage`, at `place`."
  @spec checks(Stage.t(), place()) :: [map()]
  def checks(%Stage{} = stage, place) do
    dir = artifacts_dir(place.task_id)

    artifact =
      if place.last?,
        do: %{"id" => "no_artifacts", "path" => dir},
        else: %{
          "id" => "artifact_committed",
          "path" => Prompt.artifact_path(place.task_id, place.index, stage.key)
        }

    [
      %{"id" => "branch", "branch" => place.branch},
      %{"id" => "no_operation"},
      %{"id" => "contains_origin", "branch" => place.branch},
      %{"id" => "clean", "artifacts" => dir},
      %{"id" => "no_secrets"},
      artifact
    ]
  end

  @doc "What the agent of a stage at `place` is told about the contract, in Markdown."
  @spec prompt(place()) :: String.t()
  def prompt(place) do
    dir = artifacts_dir(place.task_id)

    artifact =
      if place.last?,
        do:
          "- #{@last_stage}: tire `#{dir}/` da branch sem apagar do disco (`git rm -r --cached #{dir}`) e faça commit. A plataforma guarda os artefatos.",
        else:
          "- O artefato desta etapa está commitado, para o PR mostrar o andamento e outro agente poder continuar."

    delivery =
      if place.pr?,
        do:
          "Depois, a plataforma faz o push da branch e atualiza só a parte dela na descrição do PR. Se você mesmo fizer o push ou abrir o PR, ela os adota.",
        else: "A plataforma não faz push nesta pipeline."

    """
    # Contrato com a plataforma

    A plataforma não faz commit: faça commit do seu trabalho na branch `#{place.branch}`, adicionando o que é da tarefa. Ao terminar, ela confere:
    - o trabalho está na branch `#{place.branch}`;
    - nenhum merge, rebase ou conflito ficou pela metade;
    - a branch contém o que está no origin (integre com merge o que alguém tiver enviado, sem reescrever o que já está lá);
    - nada ficou sem commit, fora a pasta `#{dir}/`;
    - nenhum segredo do workspace aparece nas mudanças;
    #{artifact}

    Se algo não passar, você recebe o motivo numa nova tentativa. #{delivery}
    """
    |> String.trim_trailing()
  end

  @doc """
  The checks of a pipeline whose delivery is `delivery`, as people read them
  (the pipeline's form and page).
  """
  @spec labels(String.t() | nil) :: [String.t()]
  def labels(delivery) when delivery in ["commit", "pr"] do
    [
      "O trabalho está na branch da tarefa",
      "Nenhum merge, rebase ou conflito pela metade",
      "A branch contém o que está no origin",
      "Nada ficou sem commit (o agente faz os commits)",
      "Nenhum segredo do workspace nas mudanças",
      "O artefato de cada etapa está commitado; na última, os artefatos saem da branch"
    ]
  end

  def labels(_delivery), do: []
end
