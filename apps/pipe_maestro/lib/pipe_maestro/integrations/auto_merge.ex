defmodule PipeMaestro.Integrations.AutoMerge do
  @moduledoc """
  Merges the pull request of a task whose pipeline asks for it
  (`PipeMaestro.Pipelines.Pipeline` `auto_merge`), once the task succeeded
  and its `merge_state` is `"waiting_checks"`.

  `check/1` looks at the pull request on the host each time it runs (the
  worker, `PipeMaestro.Integrations.AutoMergeWorker`, and every change of the
  task) and either waits, merges, or sends the task back:

  - it waits while the pull request is still a draft, its head is not the
    task's last commit pushed, the host has not worked out whether it merges
    cleanly, or a check is still running; a conflict counts once seen twice
    at the same head, since a host may report one while it still works it
    out;
  - with no conflict and every check passed (or none at all), it merges with
    the pipeline's `merge_method`, its head as the expected commit;
  - a check that failed, or a conflict with the base branch, becomes a
    correction stage (`PipeMaestro.Tasks.correct/3`, `merge_fix: true`) with
    what went wrong, up to the pipeline's `max_merge_fixes` corrections;
    past that, the merge is blocked and the task's people are told.

  The platform's own checks (`pipemaestro/<stage>`) do not count. A merge the
  host refuses, or checks that do not end within `@max_wait_hours`, block
  the merge without a correction: no stage would fix them.
  """

  import Ecto.Query

  require Logger

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.{Integrations, Repo, Tasks}
  alias PipeMaestro.Integrations.{Credentials, Feedback, LinkedRepo}
  alias PipeMaestro.Tasks.Task

  @own_checks "pipemaestro/"
  @max_wait_hours 6

  @typedoc "What a check found."
  @type outcome :: :skipped | :waiting | :merged | :fixing | :blocked | {:error, String.t()}

  @doc "The ids of the tasks waiting for their pull request's checks."
  @spec waiting_task_ids() :: [Ecto.UUID.t()]
  def waiting_task_ids do
    Repo.all(
      from t in Task,
        where: t.merge_state == "waiting_checks" and t.status == :succeeded,
        select: t.id
    )
  end

  @doc """
  Looks at the pull request of the task with `task_id` and acts on what it
  finds, one check at a time per task.
  """
  @spec check(Ecto.UUID.t(), DateTime.t()) :: outcome()
  def check(task_id, now \\ DateTime.utc_now()) when is_binary(task_id) do
    :global.trans({{__MODULE__, task_id}, self()}, fn -> do_check(task_id, now) end)
  end

  defp do_check(task_id, now) do
    with %Task{status: :succeeded, merge_state: "waiting_checks"} = task <-
           Repo.get(Task, task_id),
         %LinkedRepo{} = repo <- task.linked_repo_id && Repo.get(LinkedRepo, task.linked_repo_id),
         repo = Repo.preload(repo, :connection),
         number when is_integer(number) <- task.issue_feedback["pr_number"],
         {:ok, client} <- Credentials.client(repo.connection) do
      if overdue?(task, now),
        do: block(task, "os checks do PR não terminaram em #{@max_wait_hours} horas"),
        else: look(task, repo, client, number)
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _not_waiting_or_no_pr_yet -> :skipped
    end
  end

  defp overdue?(%Task{merge_waiting_since: nil}, _now), do: false

  defp overdue?(%Task{merge_waiting_since: since}, now),
    do: DateTime.diff(now, since, :hour) >= @max_wait_hours

  defp look(task, repo, client, number) do
    with {:ok, pr} <- client.provider.get_pr(client, repo.full_name, number),
         {:ok, checks} <- checks(task, repo, client, pr) do
      decide(task, repo, client, pr, checks)
    else
      {:error, error} -> {:error, Integrations.describe(error)}
    end
  end

  # Checks are only read for a pull request that could merge now.
  defp checks(task, repo, client, pr) do
    if open_at_head?(task, pr) and pr.mergeable == true,
      do: own_checks_out(client.provider.pr_checks(client, repo.full_name, pr.head_sha)),
      else: {:ok, []}
  end

  defp own_checks_out({:ok, checks}),
    do: {:ok, Enum.reject(checks, &String.starts_with?(&1.name || "", @own_checks))}

  defp own_checks_out(error), do: error

  # Ready, open and at the task's last commit pushed: the feedback marks it
  # ready, and a push may still be on its way.
  defp open_at_head?(task, pr),
    do: not pr.merged and pr.state != "closed" and not pr.draft and pr.head_sha == task.head_sha

  defp decide(task, _repo, _client, %{merged: true}, _checks), do: merged(task)

  defp decide(task, _repo, _client, %{state: "closed"}, _checks),
    do: block(task, "o PR foi fechado sem o merge")

  defp decide(task, repo, client, pr, checks) do
    failed = Enum.filter(checks, &(&1.state == :failure))

    cond do
      not open_at_head?(task, pr) -> :waiting
      pr.mergeable == false -> conflict(task, pr)
      is_nil(pr.mergeable) -> :waiting
      failed != [] -> fix(task, checks_prompt(failed), failed_reason(failed))
      Enum.any?(checks, &(&1.state == :pending)) -> :waiting
      true -> merge(task, repo, client, pr)
    end
  end

  # A host may say a pull request does not merge while it still works it out
  # after a push (Forgejo does): a conflict counts when seen twice at the
  # same head.
  defp conflict(task, pr) do
    if task.issue_feedback["conflict_sha"] == pr.head_sha do
      fix(task, conflict_prompt(pr), "o PR conflita com `#{pr.base}`")
    else
      task
      |> Ecto.Changeset.change(
        issue_feedback: Map.put(task.issue_feedback, "conflict_sha", pr.head_sha)
      )
      |> Repo.update!()

      :waiting
    end
  end

  defp merge(task, repo, client, pr) do
    method = task.pipeline_context["merge_method"] || "squash"

    case client.provider.merge_pr(client, repo.full_name, pr.number, %{
           method: method,
           sha: pr.head_sha
         }) do
      :ok ->
        merged(task)

      {:error, %{status: status} = error} when status in [405, 409, 422] ->
        block(task, "o host recusou o merge (#{Integrations.describe(error)})")

      {:error, error} ->
        {:error, Integrations.describe(error)}
    end
  end

  defp merged(task) do
    task =
      task
      |> Ecto.Changeset.change(issue_feedback: Map.put(task.issue_feedback, "merged", true))
      |> Repo.update!()

    Tasks.put_merge(task, %{merge_state: "merged", merge_reason: nil})
    _ = Feedback.sync(task.id)
    :merged
  end

  defp block(task, reason) do
    Tasks.put_merge(task, %{merge_state: "blocked", merge_reason: reason})
    :blocked
  end

  defp fix(task, prompt, reason) do
    max = task.pipeline_context["max_merge_fixes"] || 0

    if task.merge_fixes < max do
      owner = task.created_by_user_id && Repo.get(User, task.created_by_user_id)

      case Tasks.correct(task, prompt, by: owner, via: "merge automático", merge_fix: true) do
        {:ok, _task} ->
          :fixing

        {:error, why} ->
          Logger.warning("Correção para o merge da tarefa #{task.id} recusada: #{inspect(why)}")
          block(task, "#{reason}, e a correção não pôde começar (#{why})")
      end
    else
      block(task, "#{reason}, depois de #{max} correções")
    end
  end

  defp failed_reason(failed),
    do: "falharam os checks: " <> Enum.map_join(failed, ", ", &"`#{&1.name}`")

  defp checks_prompt(failed) do
    lines =
      Enum.map_join(failed, "\n", fn check ->
        summary = if check.summary not in [nil, ""], do: ": #{check.summary}", else: ""
        url = if check.url, do: " (#{check.url})", else: ""
        "- `#{check.name}`#{summary}#{url}"
      end)

    """
    O PR da tarefa não pôde ser integrado: estes checks do repositório falharam no último commit.

    #{lines}

    Descubra a causa (rode localmente o que o check roda; os logs ficam no link, quando houver), corrija na branch e valide de novo. Não desligue nem contorne o check.
    """
  end

  defp conflict_prompt(pr) do
    """
    O PR da tarefa não pôde ser integrado: a branch conflita com `#{pr.base}`.

    Traga o que mudou na base (`git fetch origin #{pr.base}` e `git merge origin/#{pr.base}`), resolva os conflitos mantendo o que as duas partes querem, rode os testes e o lint e faça o commit do merge.
    """
  end
end
