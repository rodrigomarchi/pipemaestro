defmodule PipeMaestro.Proposals do
  @moduledoc """
  A pipeline and a project configuration proposed by the agent, from a
  person's request and a study of the code.

  A proposal is a job (`PipeMaestro.Jobs`) sent to a runner that runs it in a
  disposable worktree of one of its git directories (`scratch`,
  `PipeMaestroProtocol.Job`): the agent reads, builds and runs the project's
  commands, and nothing it does reaches the directory. Only runners that
  announce the `"scratch"` capability take one. The agent answers in
  `PipeMaestro.Proposals.Schema`; `result/1` turns the answer into attributes
  for the project and pipeline forms, which a person reviews and saves.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Jobs
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Pipelines.Yaml
  alias PipeMaestro.Proposals.{Instructions, Schema}
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Workspaces.Workspace

  @capability "scratch"
  @max_budget_usd 3
  @timeout_ms 20 * 60 * 1000
  @types %{runner_id: :binary_id, directory: :string, request: :string, feedback: :string}

  @typedoc "What `result/1` reads from a finished proposal."
  @type result :: %{
          analysis: String.t(),
          checks: [map()],
          project: map(),
          pipeline: map()
        }

  @doc "The capability a runner must announce to take a proposal."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "Whether `runner` can run a proposal."
  @spec capable?(Runner.t()) :: boolean()
  def capable?(%Runner{} = runner), do: Runners.capable?(runner, @capability)

  @doc "A changeset for the form that asks for a proposal."
  @spec change_request(map()) :: Changeset.t()
  def change_request(attrs \\ %{}) do
    {%{}, @types}
    |> Changeset.cast(attrs, Map.keys(@types))
    |> Changeset.validate_required([:runner_id], message: "escolha um runner online")
    |> Changeset.validate_required([:directory], message: "escolha o diretório do projeto")
    |> Changeset.validate_required([:request], message: "conte o que o pipeline deve fazer")
    |> Changeset.validate_length(:request, max: 8_000)
    |> Changeset.validate_length(:feedback, max: 4_000)
  end

  @doc """
  Asks a runner of `workspace` for a proposal: `runner_id`, `directory` (one
  of its git directories) and `request`. A new round of `previous` (a
  proposal's job) also takes the person's `feedback`.
  """
  @spec request(User.t(), Workspace.t(), map(), Job.t() | nil) ::
          {:ok, Job.t()} | {:error, Changeset.t()}
  def request(%User{} = user, %Workspace{} = workspace, attrs, previous \\ nil) do
    changeset = attrs |> change_request() |> validate_runner(workspace)

    with {:ok, %{runner_id: runner_id, directory: directory, request: request} = data} <-
           Changeset.apply_action(changeset, :insert) do
      previous_output = previous && previous.structured_output
      prompt = Instructions.prompt(request, directory, previous_output, data[:feedback])

      context = %{
        "directory" => directory,
        "scratch" => true,
        "system_prompt" => Instructions.system_prompt(),
        "output_schema" => Schema.schema(),
        "max_budget_usd" => @max_budget_usd,
        "timeout_ms" => @timeout_ms,
        "proposal" => %{"directory" => directory, "request" => request}
      }

      case Jobs.create_job(user, workspace, %{prompt: prompt, runner_id: runner_id}, context) do
        {:ok, job} -> {:ok, job}
        {:error, job_changeset} -> {:error, %{changeset | errors: job_changeset.errors}}
      end
    end
  end

  # The runner must be the workspace's, able to run a disposable worktree,
  # and offer the directory as a git repository.
  defp validate_runner(changeset, workspace) do
    with runner_id when is_binary(runner_id) <- Changeset.get_field(changeset, :runner_id),
         %Runner{} = runner <- runner(workspace, runner_id) do
      directory = Changeset.get_field(changeset, :directory)

      cond do
        not capable?(runner) ->
          Changeset.add_error(changeset, :runner_id, "atualize este runner para gerar propostas")

        directory && not git_directory?(runner, directory) ->
          Changeset.add_error(changeset, :directory, "precisa ser um repositório git do runner")

        true ->
          changeset
      end
    else
      nil -> changeset
      :none -> Changeset.add_error(changeset, :runner_id, "não é um runner ativo deste workspace")
    end
  end

  defp runner(workspace, runner_id) do
    Enum.find(Runners.list_runners(workspace), :none, &(&1.id == runner_id))
  end

  @doc "Whether `runner` offers `directory` as a git repository."
  @spec git_directory?(Runner.t(), String.t()) :: boolean()
  def git_directory?(%Runner{directories: directories}, directory),
    do: Enum.any?(directories || [], &(&1["name"] == directory and &1["git"] == true))

  @doc "The workspace's latest proposals, newest first."
  @spec list_recent(Workspace.t(), pos_integer()) :: [Job.t()]
  def list_recent(%Workspace{id: workspace_id}, limit \\ 10) do
    Repo.all(
      from j in Job,
        where: j.workspace_id == ^workspace_id,
        where: fragment("(?->'proposal') IS NOT NULL", j.context),
        order_by: [desc: j.inserted_at],
        limit: ^limit,
        preload: [:runner]
    )
  end

  @doc "A proposal of `workspace` by its job's id."
  @spec get_proposal!(Workspace.t(), Ecto.UUID.t()) :: Job.t()
  def get_proposal!(%Workspace{} = workspace, id) do
    job = Jobs.get_job!(workspace, id)
    if proposal?(job), do: job, else: raise(Ecto.NoResultsError, queryable: Job)
  end

  @doc "Whether `job` is a proposal."
  @spec proposal?(Job.t()) :: boolean()
  def proposal?(%Job{context: context}), do: is_map(context && context["proposal"])

  @doc "The directory and request a proposal was asked with."
  @spec asked(Job.t()) :: %{directory: String.t(), request: String.t()}
  def asked(%Job{context: %{"proposal" => proposal}}),
    do: %{directory: proposal["directory"], request: proposal["request"]}

  @doc """
  What a finished proposal says: the agent's analysis and checks, attributes
  for the directory's project (`PipeMaestro.Projects.create_project/3`) and
  for the pipeline (`PipeMaestro.Pipelines.create_pipeline/2`).
  """
  @spec result(Job.t()) :: {:ok, result()} | {:error, String.t()}
  def result(%Job{status: :succeeded, structured_output: %{} = output} = job) do
    with %{} = project <- output["projeto"],
         %{"stages" => [_ | _]} = pipeline <- output["pipeline"] do
      {:ok,
       %{
         analysis: text(output["analise"]),
         checks: checks(output["verificacoes"]),
         project: project_attrs(project, asked(job).directory),
         pipeline: Yaml.from_map(pipeline)
       }}
    else
      _incomplete -> {:error, "O agente não devolveu um projeto e um pipeline com etapas."}
    end
  end

  def result(%Job{status: :succeeded}),
    do: {:error, "O agente terminou sem devolver a proposta no formato pedido."}

  def result(%Job{error: error}) when is_binary(error), do: {:error, error}
  def result(%Job{}), do: {:error, "A proposta não terminou bem."}

  defp project_attrs(project, directory) do
    %{
      "name" => text(project["nome"]),
      "directory" => directory,
      "setup_command" => text(project["setup"]),
      "test_command" => text(project["teste"]),
      "lint_command" => text(project["lint"]),
      "copy_paths_text" => project["copy_paths"] |> List.wrap() |> Enum.join("\n"),
      "notes" => text(project["notas"])
    }
  end

  defp checks(list) when is_list(list) do
    for %{"comando" => command} = check <- list, is_binary(command) do
      %{
        command: command,
        passed: check["passou"] == true,
        note: text(check["observacao"])
      }
    end
  end

  defp checks(_other), do: []

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""
end
