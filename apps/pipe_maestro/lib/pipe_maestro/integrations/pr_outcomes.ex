defmodule PipeMaestro.Integrations.PrOutcomes do
  @moduledoc """
  The outcome of the pull request each task delivers on a linked repository
  (`PipeMaestro.Integrations.PrOutcome`,
  [ADR 0054](docs/adr/0054-qualidade-das-entregas.md)):

  - `ready/1`, when the task succeeds with its pull request (from
    `PipeMaestro.Tasks` and from `PipeMaestro.Integrations.Feedback`, which may
    open it after the task ended), records it once;
  - `merged/2`, `closed/2` and `review_round/2` record what the host's
    events say (`PipeMaestro.Integrations.Conversation`,
    `PipeMaestro.Integrations.AutoMerge`), each idempotent;
  - `observe/1` reads the pull request's commits and tells the pipeline's
    from a person's, by SHA: when the task has a commit of the pipeline not
    yet taken into account (its `head_sha`) and the pull request has it,
    the commits up to it are the pipeline's and those after it a person's;
    otherwise any commit the pipeline did not push is a person's. A merge
    commit (more than one parent) is nobody's change. It runs after each
    change of the task (`PipeMaestro.Integrations.FeedbackWorker`), on the
    merge and the close, and in the reconciliation (`reconcile/1`), which
    also finds a merge the webhook missed.

  A host that fails leaves its message in `commits_error` for the
  reconciliation; nothing here stops a task.
  """

  import Ecto.Query

  alias PipeMaestro.{Integrations, Repo}
  alias PipeMaestro.Integrations.{Connection, Credentials, LinkedRepo, PrOutcome}
  alias PipeMaestro.Tasks.Task

  @doc """
  Records that `task` is ready, the first time it succeeded with its pull
  request on a linked repository; later calls only fill in the pull
  request's number. Answers the outcome, or `nil` for a task that is not
  such a delivery.
  """
  @spec ready(Task.t()) :: PrOutcome.t() | nil
  def ready(
        %Task{
          status: :succeeded,
          pr_url: url,
          linked_repo_id: repo_id,
          workspace_id: workspace_id
        } =
          task
      )
      when is_binary(url) and is_binary(repo_id) do
    number = pr_number(task)

    Repo.insert!(
      %PrOutcome{
        task_id: task.id,
        workspace_id: workspace_id,
        linked_repo_id: repo_id,
        pr_url: url,
        pr_number: number,
        ready_at: task.finished_at || DateTime.utc_now(:second),
        commits_tracked: tracked?(repo_id)
      },
      on_conflict: :nothing,
      conflict_target: :task_id
    )

    if number,
      do:
        Repo.update_all(
          from(o in PrOutcome, where: o.task_id == ^task.id and is_nil(o.pr_number)),
          set: [pr_number: number, pr_url: url]
        )

    get(task.id)
  end

  def ready(%Task{}), do: nil

  @doc "The outcome of the task's pull request, if it was delivered."
  @spec get(Ecto.UUID.t()) :: PrOutcome.t() | nil
  def get(task_id), do: Repo.get_by(PrOutcome, task_id: task_id)

  @doc """
  The pull request was merged at `at` (now when the host does not say).
  Only an open outcome changes: a merge told again changes nothing.
  """
  @spec merged(Task.t(), DateTime.t() | nil) :: boolean()
  def merged(%Task{id: task_id}, at) do
    at = at || DateTime.utc_now(:second)
    settle(task_id, state: "merged", merged_at: at, closed_at: at)
  end

  @doc "The pull request was closed without the merge at `at`; as `merged/2`."
  @spec closed(Task.t(), DateTime.t() | nil) :: boolean()
  def closed(%Task{id: task_id}, at),
    do: settle(task_id, state: "closed", closed_at: at || DateTime.utc_now(:second))

  defp settle(task_id, changes) do
    {count, _} =
      Repo.update_all(
        from(o in PrOutcome, where: o.task_id == ^task_id and o.state == "open"),
        set: changes ++ [updated_at: DateTime.utc_now(:second)]
      )

    count == 1
  end

  @doc "Whether the review `key` already became a correction of the task's pull request."
  @spec reviewed?(Task.t(), String.t()) :: boolean()
  def reviewed?(%Task{id: task_id}, key) do
    Repo.exists?(
      from o in PrOutcome,
        where: o.task_id == ^task_id and fragment("? = ANY(?)", ^key, o.review_keys)
    )
  end

  @doc """
  Counts a review asking for changes (`key`, the review's or its
  delivery's id) that became a correction, once.
  """
  @spec review_round(Task.t(), String.t()) :: boolean()
  def review_round(%Task{id: task_id}, key) do
    {count, _} =
      Repo.update_all(
        from(o in PrOutcome,
          where: o.task_id == ^task_id and not fragment("? = ANY(?)", ^key, o.review_keys),
          update: [
            inc: [review_rounds: 1],
            set: [review_keys: fragment("array_append(?, ?)", o.review_keys, ^key)]
          ]
        ),
        []
      )

    count == 1
  end

  @doc """
  Reads the pull request's commits and tells the pipeline's from a
  person's (see the module's doc). `:skipped` for a task without an outcome
  or whose commits the platform may not read; `{:error, message}` when the
  host failed, kept in `commits_error`. One at a time per task.
  """
  @spec observe(Ecto.UUID.t()) :: :ok | :skipped | {:error, String.t()}
  def observe(task_id) when is_binary(task_id) do
    :global.trans({{__MODULE__, task_id}, self()}, fn -> do_observe(task_id) end)
  end

  defp do_observe(task_id) do
    with %PrOutcome{commits_tracked: true} = outcome <- get(task_id),
         %Task{} = task <- Repo.get(Task, task_id),
         number when is_integer(number) <- outcome.pr_number || pr_number(task),
         {:ok, client, repo} <- client(outcome) do
      case client.provider.pr_commits(client, repo.full_name, number) do
        {:ok, commits} ->
          outcome |> Ecto.Changeset.change(sort(outcome, task, commits)) |> Repo.update!()
          :ok

        {:error, error} ->
          fail(outcome, Integrations.describe(error))
      end
    else
      {:error, message} when is_binary(message) -> fail(get(task_id), message)
      _not_tracked -> :skipped
    end
  end

  defp fail(outcome, message) do
    outcome |> Ecto.Changeset.change(commits_error: message) |> Repo.update!()
    {:error, message}
  end

  # The changes to the outcome after reading the pull request's `commits`.
  defp sort(outcome, task, commits) do
    shas = Enum.map(commits, & &1.sha)
    merges = for %{sha: sha, parents: [_, _ | _]} <- commits, into: MapSet.new(), do: sha
    head = task.head_sha
    new_head? = is_binary(head) and head != outcome.observed_head and head in shas

    {pipeline, others, observed} =
      if new_head? do
        {upto, after_head} = Enum.split(shas, Enum.find_index(shas, &(&1 == head)) + 1)
        {Enum.reject(upto, &(&1 in outcome.human_shas)), after_head, head}
      else
        {[], shas, outcome.observed_head}
      end

    pipeline_shas = add_new(outcome.pipeline_shas, pipeline)

    human =
      Enum.reject(others, &(&1 in pipeline_shas or MapSet.member?(merges, &1)))

    [
      pipeline_shas: pipeline_shas,
      human_shas: add_new(outcome.human_shas, human),
      observed_head: observed,
      pr_number: outcome.pr_number || pr_number(task),
      commits_error: nil,
      commits_final: outcome.state != "open"
    ]
  end

  defp add_new(kept, new), do: Enum.uniq(kept ++ new)

  @doc """
  The ids of the tasks whose outcome the reconciliation still looks at: an
  open pull request, commits not read after the merge or the close, or a
  host that failed; only those the platform may read.
  """
  @spec pending_task_ids() :: [Ecto.UUID.t()]
  def pending_task_ids do
    Repo.all(
      from o in PrOutcome,
        where: o.commits_tracked,
        where: o.state == "open" or not o.commits_final or not is_nil(o.commits_error),
        select: o.task_id
    )
  end

  @doc """
  Looks at the task's pull request on the host: a merge or a close the
  webhook missed is recorded, with the host's date, and its commits are read
  (`observe/1`). Answers whether it found the pull request merged or closed.
  """
  @spec reconcile(Ecto.UUID.t()) :: boolean()
  def reconcile(task_id) do
    with %PrOutcome{state: "open"} = outcome <- get(task_id),
         %Task{} = task <- Repo.get(Task, task_id),
         number when is_integer(number) <- outcome.pr_number || pr_number(task),
         {:ok, client, repo} <- client(outcome) do
      case client.provider.get_pr(client, repo.full_name, number) do
        {:ok, pr} ->
          settled = settle_from_host(task, pr)
          _ = observe(task_id)
          settled

        {:error, error} ->
          _ = fail(outcome, Integrations.describe(error))
          false
      end
    else
      %PrOutcome{} ->
        _ = observe(task_id)
        false

      {:error, message} when is_binary(message) ->
        _ = fail(get(task_id), message)
        false

      _nothing ->
        false
    end
  end

  defp settle_from_host(task, %{merged: true} = pr), do: merged(task, pr[:merged_at])

  defp settle_from_host(task, %{state: "closed"} = pr), do: closed(task, pr[:closed_at])

  defp settle_from_host(_task, _open), do: false

  defp client(%PrOutcome{linked_repo_id: nil}),
    do: {:error, "o repositório não está mais vinculado"}

  defp client(%PrOutcome{linked_repo_id: repo_id}) do
    with %LinkedRepo{} = repo <- Repo.get(LinkedRepo, repo_id),
         %Connection{} = connection <- Repo.get(Connection, repo.connection_id),
         {:ok, client} <- Credentials.client(connection) do
      {:ok, client, repo}
    else
      nil -> {:error, "o repositório não está mais vinculado"}
      {:error, message} -> {:error, message}
    end
  end

  # The platform reads the commits only where it may call the host.
  defp tracked?(repo_id) do
    Repo.exists?(
      from r in LinkedRepo,
        join: c in assoc(r, :connection),
        where: r.id == ^repo_id and c.api_mode == "control_plane"
    )
  end

  # The number the feedback kept, or the last number in the pull request's link.
  defp pr_number(%Task{issue_feedback: %{"pr_number" => number}}) when is_integer(number),
    do: number

  defp pr_number(%Task{pr_url: url}) when is_binary(url) do
    case Regex.run(~r{/(\d+)/?$}, url) do
      [_, number] -> String.to_integer(number)
      nil -> nil
    end
  end

  defp pr_number(%Task{}), do: nil
end
