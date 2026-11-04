defmodule PipeMaestro.Proposals do
  @moduledoc """
  Something the agent proposes for a person to review: a pipeline and its
  project, a task written from an idea, the decision a paused task waits for,
  or improvements to a pipeline from its history. Each kind
  (`PipeMaestro.Proposals.Kind`) says what is asked, how the agent is asked
  and how its answer is read; this module is what they share.

  A proposal is a job (`PipeMaestro.Jobs`) whose context carries
  `"proposal" => %{"kind", "input", "title"}`, a key of the control plane's
  own that never reaches the runner. A job with a directory runs in a
  disposable worktree of it (`scratch`, `PipeMaestroProtocol.Job`): the agent
  reads, builds and runs the project's commands, and nothing it does reaches
  the directory. Only runners that announce the `"scratch"` capability take
  one, and only a git directory can be studied. The agent answers in the
  kind's JSON Schema, and `result/1` reads the answer for the review.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Jobs
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Pipelines
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Proposals.{DecisionKind, ImproveKind, Instructions, PipelineKind, TaskKind}
  alias PipeMaestro.Repo
  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Workspaces.Workspace

  @capability "scratch"
  # The job's prompt stays under the wire's limit (PipeMaestroProtocol.Job).
  @prompt_bytes 30_000
  @kinds %{
    "pipeline" => PipelineKind,
    "task" => TaskKind,
    "decision" => DecisionKind,
    "improve" => ImproveKind
  }

  @doc "The kinds of proposal, by name."
  @spec kinds() :: [String.t()]
  def kinds, do: ~w(pipeline task decision improve)

  @doc "The module of kind `name` (`PipeMaestro.Proposals.Kind`)."
  @spec kind_module(String.t()) :: module()
  def kind_module(name), do: Map.fetch!(@kinds, name)

  @doc "The capability a runner must announce to study a directory."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "Whether `runner` can study a directory in a disposable worktree."
  @spec capable?(Runner.t()) :: boolean()
  def capable?(%Runner{} = runner), do: Runners.capable?(runner, @capability)

  @doc "Whether `runner` offers `directory` as a git repository."
  @spec git_directory?(Runner.t(), String.t()) :: boolean()
  def git_directory?(%Runner{directories: directories}, directory),
    do: Enum.any?(directories || [], &(&1["name"] == directory and &1["git"] == true))

  @doc "A changeset for the form that asks for a proposal of `kind`."
  @spec change_request(String.t(), Workspace.t(), map()) :: Changeset.t()
  def change_request(kind, %Workspace{} = workspace, attrs \\ %{}),
    do: kind_module(kind).changeset(attrs, workspace)

  @doc """
  Asks the agent for a proposal of `kind` in `workspace`. A new round of
  `previous` (a proposal of the same kind) carries the person's `feedback`
  among the `attrs`.
  """
  @spec request(String.t(), User.t(), Workspace.t(), map(), Job.t() | nil) ::
          {:ok, Job.t()} | {:error, Changeset.t()}
  def request(kind, %User{} = user, %Workspace{} = workspace, attrs, previous \\ nil) do
    module = kind_module(kind)
    changeset = attrs |> module.changeset(workspace) |> validate_runner(workspace)

    with {:ok, data} <- Changeset.apply_action(changeset, :insert) do
      spec = module.job(data, workspace, previous)
      directory = data[:directory]

      context =
        %{
          "system_prompt" => spec.system_prompt,
          "output_schema" => spec.output_schema,
          "max_budget_usd" => spec.max_budget_usd,
          "timeout_ms" => spec.timeout_ms,
          "proposal" => %{"kind" => kind, "input" => stored_input(data), "title" => spec.title}
        }
        |> then(
          &if(directory,
            do: Map.merge(&1, %{"directory" => directory, "scratch" => true}),
            else: &1
          )
        )

      job_attrs = %{
        prompt: Instructions.cut(spec.prompt, @prompt_bytes),
        runner_id: data[:runner_id]
      }

      case Jobs.create_job(user, workspace, job_attrs, context) do
        {:ok, job} -> {:ok, job}
        {:error, job_changeset} -> {:error, %{changeset | errors: job_changeset.errors}}
      end
    end
  end

  # What the request said, as stored with the job: everything but the runner,
  # which the job already names.
  defp stored_input(data) do
    for {key, value} <- data, key != :runner_id, value != nil, into: %{} do
      {Atom.to_string(key), value}
    end
  end

  # The runner must be the workspace's; to study a directory it must also be
  # able to run a disposable worktree, and offer the directory as git.
  defp validate_runner(changeset, workspace) do
    runner_id = Changeset.get_field(changeset, :runner_id)
    directory = Changeset.get_field(changeset, :directory)

    case runner_id && Enum.find(Runners.list_runners(workspace), &(&1.id == runner_id)) do
      nil ->
        if runner_id,
          do: Changeset.add_error(changeset, :runner_id, "não é um runner ativo deste workspace"),
          else: changeset

      %Runner{} = runner ->
        cond do
          is_nil(directory) ->
            changeset

          not capable?(runner) ->
            Changeset.add_error(
              changeset,
              :runner_id,
              "atualize este runner para gerar propostas"
            )

          not git_directory?(runner, directory) ->
            Changeset.add_error(changeset, :directory, "precisa ser um repositório git do runner")

          true ->
            changeset
        end
    end
  end

  @doc "The workspace's latest proposals (of `kinds`, or all), newest first."
  @spec list_recent(Workspace.t(), [String.t()] | :all, pos_integer()) :: [Job.t()]
  def list_recent(%Workspace{id: workspace_id}, kinds \\ :all, limit \\ 50) do
    query =
      from j in Job,
        where: j.workspace_id == ^workspace_id,
        where: fragment("(?->'proposal') IS NOT NULL", j.context),
        order_by: [desc: j.inserted_at],
        limit: ^limit,
        preload: [:runner, :created_by_user]

    query =
      if kinds == :all,
        do: query,
        else:
          where(
            query,
            [j],
            fragment("coalesce(?->'proposal'->>'kind', 'pipeline')", j.context) in ^kinds
          )

    Repo.all(query)
  end

  @doc """
  Has the agent write the task for a GitHub issue (`"title"`, `"body"`,
  `"html_url"`) of `project`, whose trigger triages (`trigger_mode`
  `"triage"`), on `runner_id`, on behalf of whoever set the trigger up. The
  trigger's pipeline is suggested to the agent.
  """
  @spec triage_issue(Workspace.t(), Project.t(), map(), Ecto.UUID.t()) ::
          {:ok, Job.t()} | {:error, Changeset.t() | :no_trigger_user}
  def triage_issue(%Workspace{} = workspace, %Project{} = project, issue, runner_id) do
    case project.trigger_user_id && Repo.get(User, project.trigger_user_id) do
      %User{} = user ->
        pipeline =
          Enum.find(Pipelines.list_pipelines(workspace), &(&1.id == project.trigger_pipeline_id))

        request = """
        # #{issue["title"]}

        #{issue["body"]}
        #{if pipeline, do: "\nO gatilho deste projeto usa o pipeline **#{pipeline.name}**; prefira-o se servir.\n"}
        """

        request("task", user, workspace, %{
          "runner_id" => runner_id,
          "directory" => project.directory,
          "request" => request,
          "issue_url" => issue["html_url"]
        })

      _nobody ->
        {:error, :no_trigger_user}
    end
  end

  @doc "Whether a task proposal about GitHub issue `issue_url` is still running."
  @spec triaging?(Workspace.t(), String.t()) :: boolean()
  def triaging?(%Workspace{id: workspace_id}, issue_url) do
    Repo.exists?(
      from j in Job,
        where: j.workspace_id == ^workspace_id and j.status in [:queued, :running],
        where: fragment("?->'proposal'->>'kind' = 'task'", j.context),
        where: fragment("?->'proposal'->'input'->>'issue_url' = ?", j.context, ^issue_url)
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

  @doc "The kind of a proposal."
  @spec kind(Job.t()) :: String.t()
  def kind(%Job{context: %{"proposal" => proposal}}), do: proposal["kind"] || "pipeline"

  @doc "What a proposal was asked with (string keys)."
  @spec input(Job.t()) :: map()
  def input(%Job{context: %{"proposal" => proposal}}), do: proposal["input"] || proposal

  @doc "A proposal's title, for lists."
  @spec title(Job.t()) :: String.t()
  def title(%Job{} = job) do
    proposal = job.context["proposal"]
    proposal["title"] || input(job)["request"] || ""
  end

  @doc """
  What a finished proposal says (its kind's `result/2`), or why there is
  nothing to review.
  """
  @spec result(Job.t()) :: {:ok, map()} | {:error, String.t()}
  def result(%Job{status: :succeeded, structured_output: %{} = output} = job),
    do: kind_module(kind(job)).result(output, job)

  def result(%Job{status: :succeeded}),
    do: {:error, "O agente terminou sem devolver a proposta no formato pedido."}

  def result(%Job{error: error}) when is_binary(error), do: {:error, error}
  def result(%Job{}), do: {:error, "A proposta não terminou bem."}

  @doc "`value` when it is text, else `\"\"`: the agent's answer, read defensively."
  @spec text(term()) :: String.t()
  def text(value) when is_binary(value), do: value
  def text(_other), do: ""
end
