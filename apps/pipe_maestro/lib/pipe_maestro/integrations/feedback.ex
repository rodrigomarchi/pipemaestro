defmodule PipeMaestro.Integrations.Feedback do
  @moduledoc """
  What the platform shows on the git host about an issue it took
  (`docs/specs/integracoes.md`, section 5), when the connection lets the
  platform call the host (`api_mode` `"control_plane"`).

  The feedback of a task is a desired state, worked out from the task alone
  (`desired/3`): the state label, one status comment edited in place, a
  commit status per stage on the last commit pushed and the pull request.
  `sync/1` applies what changed since the last time (the task's
  `issue_feedback` keeps a hash of it, the comment's id and the
  notifications made) and runs one at a time per task. New comments, which
  notify people, are only for a decision to take, a pull request ready and a
  task canceled.

  Feedback never stops the work: a failure is kept in `issue_feedback`
  (`"error"`, `"dirty"`) for the screen and for the reconciliation to try
  again.
  """

  import Ecto.Query

  alias PipeMaestro.{Integrations, Repo, Tasks}
  alias PipeMaestro.Integrations.{Client, Connection, Credentials, IssueState, Labels, LinkedRepo}
  alias PipeMaestro.Tasks.{StageRun, Task}
  alias PipeMaestro.Workspaces.Workspace
  alias PipeMaestroProtocol.PrText

  @marker "<!-- pipemaestro:status -->"
  # A task's feedback that failed this many times in a row is no longer tried
  # by the reconciliation; the next change of the task tries again.
  @max_failures 20

  @doc """
  Tells the issue's author the platform took it: a 👀 reaction, the state
  label (`:triaging` or the task's status) and the status comment.
  """
  @spec acknowledge(Connection.t(), Client.t(), LinkedRepo.t(), pos_integer(), atom()) :: :ok
  def acknowledge(%Connection{api_mode: "control_plane"}, client, repo, number, status) do
    _ = client.provider.add_reaction(client, repo.full_name, {:issue, number}, "eyes")
    _ = set_state_label(client, repo, number, status)

    text =
      if status == :triaging,
        do: "A IA está lendo a issue para escrever a tarefa.",
        else: "A tarefa foi criada e vai começar."

    _ = status_note(client, repo, number, text)
    :ok
  end

  def acknowledge(_connection, _client, _repo, _number, _status), do: :ok

  @doc """
  Writes `text` in the issue's status comment, creating it the first time
  (kept in `PipeMaestro.Integrations.IssueState`, where a task that comes of
  the issue finds it).
  """
  @spec status_note(Client.t(), LinkedRepo.t(), pos_integer(), String.t()) ::
          :ok | {:error, String.t()}
  def status_note(client, repo, number, text) do
    state =
      Repo.get_by(IssueState, repo_id: repo.id, number: number) ||
        %IssueState{repo_id: repo.id, number: number}

    body = "#{@marker}\n**PipeMaestro** · #{text}"

    result =
      case state.status_comment_id &&
             client.provider.update_comment(client, repo.full_name, state.status_comment_id, body) do
        :ok -> {:ok, state.status_comment_id}
        _none_or_gone -> client.provider.create_comment(client, repo.full_name, number, body)
      end

    case result do
      {:ok, id} ->
        state
        |> Ecto.Changeset.change(status_comment_id: to_string(id))
        |> Repo.insert_or_update!()

        :ok

      {:error, error} ->
        {:error, Integrations.describe(error)}
    end
  end

  @doc "Puts the state label for `status` on the issue, taking the other state labels off."
  @spec set_state_label(Client.t(), LinkedRepo.t(), pos_integer(), atom()) ::
          :ok | {:error, map()}
  def set_state_label(client, repo, number, status) do
    case Labels.for_status(repo.label_prefix, status) do
      nil ->
        :ok

      label ->
        others = Labels.state_labels(repo.label_prefix) -- [label]
        client.provider.set_labels(client, repo.full_name, number, add: [label], remove: others)
    end
  end

  @doc """
  Tells a linked issue how its triage ended, in the background, when no task
  came of it (a task, once created, has its own feedback): the agent's
  questions or the reason the task was not created, or that the triage did
  not finish, with the link to the proposal, and the label of a decision to
  take.
  """
  @spec triage_finished(PipeMaestro.Jobs.Job.t()) :: :ok
  def triage_finished(%{
        id: job_id,
        context: %{"proposal" => %{"input" => %{"linked_repo_id" => repo_id}}}
      })
      when is_binary(repo_id) do
    _ = Integrations.background(fn -> tell_triage(job_id) end)
    :ok
  end

  def triage_finished(_job), do: :ok

  @doc false
  @spec tell_triage(Ecto.UUID.t()) :: :ok | :skipped | {:error, String.t()}
  def tell_triage(job_id) do
    job = Repo.get!(PipeMaestro.Jobs.Job, job_id)
    input = get_in(job.context, ["proposal", "input"]) || %{}

    with repo_id when is_binary(repo_id) <- input["linked_repo_id"],
         nil <- PipeMaestro.Proposals.created_task_id(job),
         %LinkedRepo{} = repo <- Repo.get(LinkedRepo, repo_id),
         %Connection{api_mode: "control_plane", status: "active"} = connection <-
           Repo.get(Connection, repo.connection_id),
         {:ok, client} <- Credentials.client(connection) do
      body = triage_comment(job, input)
      number = input["issue_number"]
      _ = set_state_label(client, repo, number, :awaiting_decision)

      _ =
        status_note(
          client,
          repo,
          number,
          "a triagem terminou sem criar a tarefa; veja o comentário abaixo."
        )

      case client.provider.create_comment(client, repo.full_name, number, body) do
        {:ok, _id} -> :ok
        {:error, error} -> {:error, Integrations.describe(error)}
      end
    else
      {:error, message} -> {:error, message}
      _not_for_the_host -> :skipped
    end
  end

  defp triage_comment(job, input) do
    workspace = Repo.get!(Workspace, job.workspace_id)
    url = "#{Integrations.public_url()}/w/#{workspace.slug}/proposals/#{job.id}"

    why =
      case {job.status, get_in(job.context, ["proposal", "auto_approve"]), input["auto_approve"]} do
        {:succeeded, %{"status" => "skipped", "reason" => reason}, _auto} ->
          "A IA leu a issue, mas a tarefa ainda não começou:\n\n#{reason}\n\n" <>
            "Complete a issue e ponha a label de novo, ou responda e crie a tarefa na plataforma."

        {:succeeded, _none, _auto} ->
          "A IA escreveu a tarefa a partir desta issue; ela espera alguém revisar e criar na plataforma."

        {status, _none, _auto} ->
          "A triagem não terminou (#{status}). Veja o motivo na plataforma e ponha a label de novo para tentar outra vez."
      end

    "**PipeMaestro** · triagem\n\n#{why}\n\n[Abrir a proposta](#{url})"
  end

  @doc """
  What the host should show for `task` of `repo`, given the status of its
  latest attempt per stage (`runs`, by stage index) and the task's address:

  - `:label`: the state label;
  - `:comment`: the status comment's text;
  - `:statuses`: one per stage started, `%{context, state, description}`;
  - `:pr`: `%{head, base, title, block, ready}`, once a commit was pushed;
  - `:notify`: the notification this state calls for, `{key, text}` or `nil`.
  """
  @spec desired(Task.t(), LinkedRepo.t(), %{non_neg_integer() => atom()}, String.t()) :: map()
  def desired(%Task{} = task, %LinkedRepo{} = repo, runs, task_url) do
    %{
      label: Labels.for_status(repo.label_prefix, task.status),
      comment: comment(task, runs, task_url),
      statuses: if(task.head_sha, do: statuses(task, runs, task_url), else: []),
      pr: task.head_sha && task.branch && pr(task, repo),
      notify: notification(task, task_url)
    }
  end

  defp comment(task, runs, task_url) do
    stages =
      task.stages
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {stage, i} ->
        "- #{mark(stage_state(task, runs, i))} #{stage.name}"
      end)

    decision =
      if task.status == :awaiting_decision do
        questions =
          (task.decision_questionnaire || %{})
          |> Map.get("perguntas", [])
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {question, n} -> "#{n}. #{question_text(question)}" end)

        "\n**Esperando uma decisão:** #{task.decision_reason}\n" <>
          if(questions == "", do: "", else: "\n#{questions}\n") <>
          "\nResponda na tarefa ou aqui, com `/pipemaestro seguir`, `/pipemaestro refazer` ou `/pipemaestro responder`.\n"
      else
        ""
      end

    pr = if task.pr_url, do: " · [pull request](#{task.pr_url})", else: ""

    """
    #{@marker}
    **PipeMaestro** · #{if task.issue_feedback["merged"], do: "integrado ✅", else: status_text(task.status)}

    [#{task.title}](#{task_url})#{pr} · pipeline #{task.pipeline_name}

    #{stages}
    #{decision}
    """
    |> String.trim()
  end

  defp question_text(question) do
    options = Enum.map_join(question["opcoes"] || [], " · ", & &1["rotulo"])
    if options == "", do: question["pergunta"], else: "#{question["pergunta"]} (#{options})"
  end

  defp status_text(:queued), do: "na fila"
  defp status_text(:running), do: "trabalhando"
  defp status_text(:awaiting_decision), do: "esperando uma decisão"
  defp status_text(:succeeded), do: "pull request pronto para revisão"
  defp status_text(:canceled), do: "cancelada"
  defp status_text(:failed), do: "falhou"

  defp mark(:success), do: "✅"
  defp mark(:pending), do: "⏳"
  defp mark(:warning), do: "✋"
  defp mark(:failure), do: "❌"
  defp mark(:error), do: "⛔"
  defp mark(nil), do: "▫️"

  # The state of stage `i`: done before the current one, the current one by
  # the task's status, nothing after it.
  defp stage_state(%Task{status: :succeeded}, _runs, _i), do: :success

  defp stage_state(task, runs, i) do
    cond do
      i < task.current_stage -> :success
      i > task.current_stage -> nil
      true -> current_state(task, runs[i])
    end
  end

  defp current_state(%Task{status: status}, _run) when status in [:queued, :running], do: :pending
  defp current_state(%Task{status: :awaiting_decision}, :failed), do: :failure
  defp current_state(%Task{status: :awaiting_decision}, _run), do: :warning
  defp current_state(%Task{status: :canceled}, _run), do: :error
  defp current_state(%Task{status: :failed}, _run), do: :failure

  defp statuses(task, runs, task_url) do
    for {stage, i} <- Enum.with_index(task.stages),
        state = stage_state(task, runs, i),
        state != nil do
      %{
        context: "pipemaestro/#{stage.key}",
        state: Atom.to_string(state),
        description: stage.name,
        target_url: task_url
      }
    end
  end

  defp pr(task, repo) do
    %{
      head: task.branch,
      base: repo.default_branch || "main",
      title: task.title,
      block: Tasks.pr_block(task),
      ready: task.status == :succeeded
    }
  end

  defp notification(%Task{status: :awaiting_decision} = task, task_url) do
    {"decision:#{task.current_stage}:#{task.decision_due_at && DateTime.to_unix(task.decision_due_at)}",
     "✋ A tarefa [#{task.title}](#{task_url}) espera uma decisão: #{task.decision_reason}"}
  end

  defp notification(%Task{status: :succeeded, pr_url: url} = task, _task_url) when is_binary(url),
    do: {"ready", "✅ O pull request de [#{task.title}](#{url}) está pronto para revisão."}

  defp notification(%Task{status: :canceled} = task, task_url),
    do: {"canceled", "⛔ A tarefa [#{task.title}](#{task_url}) foi cancelada."}

  defp notification(_task, _task_url), do: nil

  @doc """
  Applies the desired feedback of the task with `task_id` on its issue, if it
  came from a linked repository the platform may write to. Answers
  `:skipped`, `:unchanged`, `:ok` or `{:error, message}` (kept on the task).
  """
  @spec sync(Ecto.UUID.t()) :: :skipped | :unchanged | :ok | {:error, String.t()}
  def sync(task_id) when is_binary(task_id) do
    :global.trans({{__MODULE__, task_id}, self()}, fn -> do_sync(task_id) end)
  end

  defp do_sync(task_id) do
    task = Repo.get!(Task, task_id)

    with %LinkedRepo{} = repo <- task.linked_repo_id && Repo.get(LinkedRepo, task.linked_repo_id),
         repo = Repo.preload(repo, :connection),
         true <- Integrations.keeps_pull_request?(task) do
      apply_desired(task, repo)
    else
      _no -> :skipped
    end
  end

  defp apply_desired(task, repo) do
    workspace = Repo.get!(Workspace, task.workspace_id)
    task_url = "#{Integrations.public_url()}/w/#{workspace.slug}/tasks/#{task.id}"
    desired = desired(task, repo, runs(task), task_url)

    hash =
      desired |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16()

    feedback = with_issue_comment(task.issue_feedback, repo, task.issue_number)

    if feedback["synced_hash"] == hash and feedback["dirty"] != true do
      :unchanged
    else
      case Credentials.client(repo.connection) do
        {:ok, client} ->
          write(task, repo, client, desired, hash, feedback)

        {:error, message} ->
          keep(
            task,
            Map.merge(feedback, %{"error" => message, "dirty" => true}),
            {:error, message}
          )
      end
    end
  end

  # The status comment written when the issue was taken is the task's too.
  defp with_issue_comment(%{"comment_id" => _} = feedback, _repo, _number), do: feedback

  defp with_issue_comment(feedback, repo, number) do
    case Repo.get_by(IssueState, repo_id: repo.id, number: number) do
      %IssueState{status_comment_id: id} when is_binary(id) -> Map.put(feedback, "comment_id", id)
      _none -> feedback
    end
  end

  defp write(task, repo, client, desired, hash, feedback) do
    steps = [
      &write_label(&1, client, repo, task, desired),
      &write_comment(&1, client, repo, task, desired),
      &write_statuses(&1, client, repo, task, desired),
      &write_pr(&1, client, repo, task, desired),
      &write_notification(&1, client, repo, task, desired)
    ]

    case run_steps(steps, feedback) do
      {:ok, acc} ->
        keep(
          task,
          Map.merge(acc, %{
            "synced_hash" => hash,
            "error" => nil,
            "dirty" => false,
            "failures" => 0
          }),
          :ok
        )

      {:error, acc, message} ->
        failures = (acc["failures"] || 0) + 1

        keep(
          task,
          Map.merge(acc, %{"error" => message, "dirty" => true, "failures" => failures}),
          {:error, message}
        )
    end
  end

  defp write_label(acc, client, repo, task, %{label: label}) do
    if acc["label"] == label or label == nil do
      {:ok, acc}
    else
      case set_state_label(client, repo, task.issue_number, task.status) do
        :ok -> {:ok, Map.put(acc, "label", label)}
        {:error, error} -> {:error, acc, "labels: " <> Integrations.describe(error)}
      end
    end
  end

  defp write_comment(acc, client, repo, task, %{comment: body}) do
    create = fn ->
      client.provider.create_comment(client, repo.full_name, task.issue_number, body)
    end

    # A status comment someone deleted is written again.
    result =
      case acc["comment_id"] &&
             client.provider.update_comment(client, repo.full_name, acc["comment_id"], body) do
        nil -> create.()
        :ok -> {:ok, acc["comment_id"]}
        {:error, %{status: 404}} -> create.()
        {:error, _} = error -> error
      end

    case result do
      {:ok, id} -> {:ok, Map.put(acc, "comment_id", id)}
      {:error, error} -> {:error, acc, "comentário: " <> Integrations.describe(error)}
    end
  end

  defp write_statuses(acc, client, repo, task, %{statuses: statuses}) do
    steps =
      for status <- statuses, do: fn acc -> write_status(acc, client, repo, task, status) end

    run_steps(steps, acc)
  end

  # A status already written with the same state on that commit is not sent again.
  defp write_status(acc, client, repo, task, status) do
    key = "#{task.head_sha}:#{status.context}"

    if get_in(acc, ["statuses", key]) == status.state,
      do: {:ok, acc},
      else: send_status(acc, client, repo, task, status, key)
  end

  defp send_status(acc, client, repo, task, status, key) do
    case client.provider.set_commit_status(client, repo.full_name, task.head_sha, status) do
      :ok -> {:ok, Map.put(acc, "statuses", Map.put(acc["statuses"] || %{}, key, status.state))}
      {:error, error} -> {:error, acc, "status: " <> Integrations.describe(error)}
    end
  end

  # Runs the steps in order, each one with what the ones before kept, until one fails.
  defp run_steps(steps, acc), do: Enum.reduce_while(steps, {:ok, acc}, &run_step/2)

  defp run_step(step, {:ok, acc}) do
    case step.(acc) do
      {:ok, acc} -> {:cont, {:ok, acc}}
      {:error, _acc, _message} = error -> {:halt, error}
    end
  end

  defp write_pr(acc, _client, _repo, _task, %{pr: nil}), do: {:ok, acc}

  defp write_pr(acc, client, repo, task, %{pr: pr}) do
    result =
      with {:ok, found} <- client.provider.find_open_pr(client, repo.full_name, pr.head) do
        case found do
          nil ->
            client.provider.create_pr(client, repo.full_name, %{
              head: pr.head,
              base: pr.base,
              title: pr.title,
              body: PrText.wrap(pr.block),
              draft: not pr.ready
            })

          open ->
            client.provider.update_pr(client, repo.full_name, open, %{
              body: PrText.body(open.body, pr.block),
              ready: pr.ready
            })
        end
      end

    case result do
      {:ok, opened} ->
        if opened.url != task.pr_url,
          do: task |> Ecto.Changeset.change(pr_url: opened.url) |> Repo.update!()

        {:ok, Map.put(acc, "pr_number", opened.number)}

      {:error, error} ->
        {:error, acc, "pull request: " <> Integrations.describe(error)}
    end
  end

  defp write_notification(acc, _client, _repo, _task, %{notify: nil}), do: {:ok, acc}

  defp write_notification(acc, client, repo, task, %{notify: {key, text}}) do
    notified = acc["notified"] || []

    if key in notified do
      {:ok, acc}
    else
      case client.provider.create_comment(
             client,
             repo.full_name,
             task.issue_number,
             mention(client, repo, task, key) <> text
           ) do
        {:ok, _id} -> {:ok, Map.put(acc, "notified", notified ++ [key])}
        {:error, error} -> {:error, acc, "aviso: " <> Integrations.describe(error)}
      end
    end
  end

  # A decision is asked of whoever opened the issue (the platform does not
  # know who of the host is the task's decider).
  defp mention(client, repo, task, "decision:" <> _) do
    case client.provider.get_issue(client, repo.full_name, task.issue_number) do
      {:ok, %{author: author}} when is_binary(author) -> "@#{author} "
      _unknown -> ""
    end
  end

  defp mention(_client, _repo, _task, _key), do: ""

  defp keep(task, feedback, reply) do
    task |> Ecto.Changeset.change(issue_feedback: feedback) |> Repo.update!()
    reply
  end

  # The status of the latest attempt of each stage.
  defp runs(task) do
    from(r in StageRun,
      where: r.task_id == ^task.id,
      order_by: [asc: r.index, desc: r.attempt],
      distinct: r.index,
      select: {r.index, r.status}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Leaves a task's feedback for the reconciliation to write."
  @spec mark_dirty(Ecto.UUID.t()) :: :ok
  def mark_dirty(task_id) do
    Repo.update_all(
      from(t in Task,
        where: t.id == ^task_id,
        update: [
          set: [issue_feedback: fragment("? || '{\"dirty\": true}'::jsonb", t.issue_feedback)]
        ]
      ),
      []
    )

    :ok
  end

  @doc "Tasks whose feedback failed and waits to be tried again."
  @spec dirty_task_ids() :: [Ecto.UUID.t()]
  def dirty_task_ids do
    Repo.all(
      from t in Task,
        where: not is_nil(t.linked_repo_id),
        where: fragment("(?->>'dirty')::boolean", t.issue_feedback),
        where:
          fragment("coalesce((?->>'failures')::int, 0) < ?", t.issue_feedback, ^@max_failures),
        select: t.id
    )
  end
end
