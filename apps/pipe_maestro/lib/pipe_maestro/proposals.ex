defmodule PipeMaestro.Proposals do
  @moduledoc """
  Something the agent proposes for a person to review: a pipeline and its
  project, a task written from an idea, the decision a paused task waits for,
  the analysis of a task's failure (asked by the platform itself), or
  improvements to a pipeline from its history. Each kind
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

  A task proposal becomes one task at most (`create_task/4`, the task's
  `proposal_job_id`), and its id is kept with the proposal
  (`created_task_id/1`). Asked with `auto_approve`, the task is created as
  the job ends (`job_finished/1`), on behalf of who asked; when it cannot be,
  the proposal waits for review and says why (`auto_approve/1`).
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Audit
  alias PipeMaestro.Integrations.{Feedback, LinkedRepo, Trigger}
  alias PipeMaestro.Jobs
  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Projects
  alias PipeMaestro.Projects.Project

  alias PipeMaestro.Proposals.{
    AnalysisKind,
    DecisionKind,
    ImproveKind,
    Instructions,
    PipelineKind,
    TaskKind
  }

  alias PipeMaestro.Repo
  alias PipeMaestro.Runners
  alias PipeMaestro.Runners.Runner
  alias PipeMaestro.Tasks
  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.Workspaces.Workspace

  @capability "scratch"
  # The job's prompt stays under the wire's limit (PipeMaestroProtocol.Job).
  @prompt_bytes 30_000
  # What of an issue's body a triage reads; the request takes up to 16 000.
  @issue_body_bytes 12_000
  @kinds %{
    "pipeline" => PipelineKind,
    "task" => TaskKind,
    "decision" => DecisionKind,
    "analysis" => AnalysisKind,
    "improve" => ImproveKind
  }

  @doc "The kinds of proposal, by name."
  @spec kinds() :: [String.t()]
  def kinds, do: ~w(pipeline task decision analysis improve)

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
          "timeout_ms" => spec.timeout_ms,
          "proposal" => %{"kind" => kind, "input" => stored_input(data), "title" => spec.title}
        }
        |> Map.merge(scratch_context(workspace, directory))

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

  # A directory is studied in a disposable worktree, which gets the project's
  # own dependency paths when it names them (else the runner finds the usual).
  defp scratch_context(_workspace, nil), do: %{}

  defp scratch_context(workspace, directory) do
    base = %{"directory" => directory, "scratch" => true}

    case Projects.for_directory(workspace, directory) do
      %Project{copy_paths: [_ | _] = paths} -> Map.put(base, "setup", %{"copy" => paths})
      _none -> base
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
  Has the agent write the task for an issue of a linked repository
  (`%{"title", "body", "html_url", "number"}`), on `runner_id`, on behalf of
  the trigger's person. The trigger's pipeline, if any, is the one the task
  uses; with `auto_approve`, the task is created as the job ends. The task
  keeps the link to the issue.
  """
  @spec triage_linked_issue(Workspace.t(), LinkedRepo.t(), Trigger.t(), map(), Ecto.UUID.t()) ::
          {:ok, Job.t()} | {:error, Changeset.t() | :no_acting_user | :already_triaging}
  def triage_linked_issue(
        %Workspace{} = workspace,
        %LinkedRepo{} = repo,
        %Trigger{} = trigger,
        issue,
        runner_id
      ) do
    case trigger.acting_user_id && Repo.get(User, trigger.acting_user_id) do
      %User{} = user ->
        triage(workspace, user, issue, %{
          "runner_id" => runner_id,
          "directory" => repo.project.directory,
          "pipeline_id" => trigger.pipeline_id,
          "auto_approve" => trigger.auto_approve,
          "linked_repo_id" => repo.id,
          "issue_number" => issue["number"]
        })

      _nobody ->
        {:error, :no_acting_user}
    end
  end

  # One triage per issue at a time: a host may deliver the same event twice,
  # so the check and the insert run under a lock on the issue.
  defp triage(workspace, user, issue, attrs) do
    url = issue["html_url"]

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["triage:" <> url])
      if triaging?(workspace, url), do: Repo.rollback(:already_triaging)

      attrs =
        attrs
        |> Map.put("request", triage_request(issue))
        |> Map.put("issue_url", url)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      case request("task", user, workspace, attrs) do
        {:ok, job} ->
          Audit.record(workspace, user, "proposal.requested", job, %{"issue_url" => url})
          job

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # The issue's body is cut: a host allows far more than a request takes.
  defp triage_request(issue) do
    """
    # #{issue["title"]}

    #{Instructions.cut(issue["body"] || "", @issue_body_bytes)}
    """
  end

  @doc """
  The workspace's proposals, newest first, narrowed by `filters` (blank
  values ignored): `"kind"`, `"status"` (`"active"` for queued or running, or
  a job status), `"directory"` and `"user_id"` (who asked).
  """
  @spec list(Workspace.t(), map(), pos_integer()) :: [Job.t()]
  def list(%Workspace{id: workspace_id}, filters \\ %{}, limit \\ 100) do
    from(j in Job,
      where: j.workspace_id == ^workspace_id,
      where: fragment("(?->'proposal') IS NOT NULL", j.context),
      order_by: [desc: j.inserted_at],
      limit: ^limit,
      preload: [:runner, :created_by_user]
    )
    |> filter_by(filters)
    |> Repo.all()
  end

  defp filter_by(query, filters) do
    Enum.reduce(filters, query, fn
      {_key, value}, query when value in [nil, ""] ->
        query

      {"kind", kind}, query ->
        where(
          query,
          [j],
          fragment("coalesce(?->'proposal'->>'kind', 'pipeline')", j.context) == ^kind
        )

      {"status", "active"}, query ->
        where(query, [j], j.status in [:queued, :running])

      {"status", status}, query when status in ~w(succeeded failed canceled) ->
        where(query, [j], j.status == ^String.to_existing_atom(status))

      {"directory", directory}, query ->
        where(
          query,
          [j],
          fragment("?->'proposal'->'input'->>'directory'", j.context) == ^directory
        )

      {"user_id", user_id}, query ->
        case Ecto.UUID.cast(user_id) do
          {:ok, id} -> where(query, [j], j.created_by_user_id == ^id)
          :error -> query
        end

      {_unknown, _value}, query ->
        query
    end)
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

  @doc """
  Creates the task a task proposal `job` became, with `params` (its
  `result/1`'s `task_params`, as the person left them). A proposal becomes
  one task at most: a second gives an error on `proposal_job_id`.
  """
  @spec create_task(User.t(), Workspace.t(), Job.t(), map()) ::
          {:ok, Task.t()} | {:error, Changeset.t()}
  def create_task(%User{} = user, %Workspace{} = workspace, %Job{} = job, params) do
    with {:ok, task} <- Tasks.create_task(user, workspace, params, proposal: job) do
      Jobs.update_proposal(job, %{"created_task_id" => task.id})
      {:ok, task}
    end
  end

  @doc "The id of the task a task proposal became, or `nil`."
  @spec created_task_id(Job.t()) :: Ecto.UUID.t() | nil
  def created_task_id(%Job{id: id} = job) do
    case job.context["proposal"]["created_task_id"] do
      nil -> Repo.one(from t in Task, where: t.proposal_job_id == ^id, select: t.id)
      task_id -> task_id
    end
  end

  @doc """
  How the auto-approval of a task proposal went: `nil` (not asked, or not
  ended yet), `%{"status" => "created"}`, or `%{"status" => "skipped",
  "reason" => text}`.
  """
  @spec auto_approve(Job.t()) :: map() | nil
  def auto_approve(%Job{context: context}), do: context["proposal"]["auto_approve"]

  @doc """
  What happens as a proposal's job ends: a task proposal asked with
  `auto_approve`, if ready and with a pipeline, becomes its task, created and
  started (or queued) on behalf of who asked. Else it waits for review, and
  the reason is kept with it. Other proposals are left alone.
  """
  @spec job_finished(Job.t()) :: :ok
  def job_finished(%Job{context: %{"proposal" => %{"kind" => "task"}}} = job) do
    if job.status == :succeeded and input(job)["auto_approve"] == true and
         is_nil(created_task_id(job)),
       do: auto_create(job)

    # A triage of a linked issue tells the issue how it ended.
    Feedback.triage_finished(job)
    :ok
  end

  def job_finished(%Job{}), do: :ok

  defp auto_create(job) do
    with {:ok, result} <- auto_result(job),
         {:ok, user} <- requester(job),
         workspace = Repo.get!(Workspace, job.workspace_id),
         {:ok, task} <- auto_task(user, workspace, job, result.task_params) do
      Audit.record(workspace, user, "task.auto_created", task, %{"proposal_id" => job.id})
      Jobs.update_proposal(job, %{"auto_approve" => %{"status" => "created"}})
      :ok
    else
      :already_created ->
        :ok

      {:skip, reason} ->
        Jobs.update_proposal(job, %{
          "auto_approve" => %{"status" => "skipped", "reason" => reason}
        })

        :ok
    end
  end

  defp auto_result(job) do
    case result(job) do
      {:error, reason} ->
        {:skip, reason}

      {:ok, %{ready: false, questions: questions}} ->
        {:skip,
         Enum.join(
           ["O agente não considerou a tarefa pronta." | Enum.map(questions, &("- " <> &1))],
           "\n"
         )}

      {:ok, %{pipeline: nil, pipeline_name: name}} ->
        {:skip, "Nenhum pipeline do workspace corresponde ao sugerido pelo agente (\"#{name}\")."}

      {:ok, result} ->
        {:ok, result}
    end
  end

  defp requester(job) do
    case job.created_by_user_id && Repo.get(User, job.created_by_user_id) do
      %User{} = user -> {:ok, user}
      _nobody -> {:skip, "Quem pediu a proposta não está mais no workspace."}
    end
  end

  # A task already made from the proposal (by hand, at the same time) is not
  # an error of the auto-approval.
  defp auto_task(user, workspace, job, params) do
    case create_task(user, workspace, job, params) do
      {:ok, task} ->
        {:ok, task}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :proposal_job_id),
          do: :already_created,
          else: {:skip, "Não foi possível criar a tarefa: " <> errors_text(changeset)}
    end
  end

  defp errors_text(changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {_field, messages} -> messages end)
    |> Enum.join("; ")
  end

  @doc "`value` when it is text, else `\"\"`: the agent's answer, read defensively."
  @spec text(term()) :: String.t()
  def text(value) when is_binary(value), do: value
  def text(_other), do: ""
end
