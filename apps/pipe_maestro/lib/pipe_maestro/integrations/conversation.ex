defmodule PipeMaestro.Integrations.Conversation do
  @moduledoc """
  What people say to a task on its git host (`docs/specs/integracoes.md`,
  sections 6 and 7):

  - a command in a comment on the task's issue or pull request
    (`PipeMaestro.TaskSources.Commands`), from someone with write access,
    goes to the same functions as the task's screen, on behalf of whoever
    the task belongs to (`PipeMaestro.TaskSources.apply_command/3`); the host's login is kept in the audit. An applied
    command gets a 👍; one that does not apply gets an answer with the
    commands that do;
  - a review asking for changes on the pull request of a finished task
    becomes the stage "Correção N";
  - the pull request merged is told on the issue;
  - "Refazer etapa" on a stopped stage's check run (GitHub) runs it again.

  Anything else goes on to the triggers (`:continue`). Commands need the
  platform to call the host (`api_mode` `"control_plane"`).
  """

  import Ecto.Query

  alias PipeMaestro.{Audit, Repo, Tasks, TaskSources}

  alias PipeMaestro.Integrations.{
    Access,
    Connection,
    Event,
    Feedback,
    IssueState,
    LinkedRepo
  }

  alias PipeMaestro.Tasks.Task
  alias PipeMaestro.TaskSources.Commands

  @default_command "/pipemaestro"

  @typedoc "How a delivery ended, as `PipeMaestro.Integrations.Ingest` keeps it, or `:continue`."
  @type result ::
          :continue
          | {:processed, String.t(), map()}
          | {:ignored, String.t()}
          | {:failed, String.t()}

  @doc "Handles the event when it is for a task of `repo`; `:continue` otherwise."
  @spec handle(Connection.t(), LinkedRepo.t(), Event.t()) :: result()
  def handle(connection, repo, %Event{kind: :issue_comment} = event) do
    command = command(repo)
    task = task_for(repo, event)

    case {task, Commands.parse(event.comment.body, command)} do
      {nil, _parsed} ->
        :continue

      {_task, :none} ->
        :continue

      {task, {:unknown, _word}} ->
        if Task.active?(task), do: unknown(connection, repo, event, command), else: :continue

      {task, {:ok, parsed}} ->
        once(repo, event, fn -> apply_command(connection, repo, task, event, parsed, command) end)
    end
  end

  def handle(connection, repo, %Event{kind: :pr_review, review: %{state: :rejected}} = event) do
    case task_for(repo, event) do
      nil ->
        :continue

      %Task{status: status} = task when status in [:succeeded, :canceled] ->
        correct_from_review(connection, repo, task, event)

      _active ->
        {:ignored, "a tarefa ainda está em andamento; o review fica para quando ela terminar"}
    end
  end

  def handle(_connection, _repo, %Event{kind: :pr_review}),
    do: {:ignored, "review sem pedido de mudanças"}

  def handle(_connection, repo, %Event{kind: :pr_closed, pr: %{merged: true}} = event) do
    case task_for(repo, event) do
      nil ->
        :continue

      task ->
        task
        |> Ecto.Changeset.change(issue_feedback: Map.put(task.issue_feedback, "merged", true))
        |> Repo.update!()

        _ = Feedback.sync(task.id)
        {:processed, "pull request integrado", %{task_id: task.id}}
    end
  end

  def handle(_connection, _repo, %Event{kind: :pr_closed}),
    do: {:ignored, "pull request fechado sem integrar"}

  # "Refazer etapa" on a stopped stage's check run (GitHub).
  def handle(
        connection,
        repo,
        %Event{kind: :check_action, check: %{action: "retry", head_sha: sha}} = event
      ) do
    with %Task{} = task <- task_for_commit(repo, sha) || {:ignored, "nenhuma tarefa nesse commit"},
         {:ok, client} <- client(connection),
         :ok <- Access.writer(client, repo, event.sender) do
      case Tasks.retry_stage(task, nil,
             by: TaskSources.owner(task),
             via: "#{provider_name(connection)}: #{event.sender}"
           ) do
        {:ok, task} ->
          {:processed, "etapa refeita a pedido de #{event.sender}", %{task_id: task.id}}

        {:error, :not_awaiting} ->
          {:ignored, "a tarefa não espera uma decisão agora"}
      end
    end
  end

  def handle(_connection, _repo, %Event{kind: :check_action}),
    do: {:ignored, "ação de check sem uso"}

  def handle(_connection, _repo, _event), do: :continue

  defp task_for_commit(repo, sha) when is_binary(sha), do: latest_task(repo, head_sha: sha)
  defp task_for_commit(_repo, _sha), do: nil

  # A review's text goes into the agent's prompt: only a writer's.
  defp correct_from_review(connection, repo, task, event) do
    with {:ok, client} <- client(connection),
         :ok <- Access.writer(client, repo, event.sender) do
      prompt = review_prompt(client, repo, event)

      case Tasks.correct(task, prompt,
             by: TaskSources.owner(task),
             via: "#{provider_name(connection)}: #{event.sender}"
           ) do
        {:ok, task} -> {:processed, "correção pedida pelo review", %{task_id: task.id}}
        {:error, reason} -> {:ignored, "a correção não pôde começar (#{reason})"}
      end
    end
  end

  # The review's text and its comments on lines of the code.
  defp review_prompt(client, repo, event) do
    lines =
      case client.provider.review_comments(client, repo.full_name, event.pr.number, event.review) do
        {:ok, comments} -> Enum.map_join(comments, "\n", &"- `#{&1.path}`#{line(&1)}: #{&1.body}")
        {:error, _} -> ""
      end

    "Pedido de mudanças no review do pull request, por @#{event.sender}:\n\n#{event.review.body}" <>
      if(lines == "", do: "", else: "\n\nComentários nas linhas:\n\n" <> lines)
  end

  defp line(%{line: nil}), do: ""
  defp line(%{line: line}), do: " (linha #{line})"

  # The repository's comment command, or the default one.
  defp command(%LinkedRepo{triggers: triggers}) when is_list(triggers) do
    Enum.find_value(triggers, @default_command, &(&1.kind == "comment" && &1.command))
  end

  defp command(_repo), do: @default_command

  # The task of the issue (its latest), or of the pull request (by branch).
  defp task_for(repo, %Event{issue: %{is_pull: false, number: number}}) do
    Repo.one(
      from t in Task,
        where: t.linked_repo_id == ^repo.id,
        where: fragment("(?->>'number')::int = ?", t.source_ref, ^number),
        order_by: [desc: t.inserted_at],
        limit: 1
    )
  end

  # A pull request: by its link (a comment on it, whose issue's link is the
  # pull request's) or by its branch.
  defp task_for(repo, %Event{issue: issue, pr: pr}) do
    url = issue && issue.is_pull && issue.url
    branch = pr && pr.head

    Enum.find_value([pr_url: url, branch: branch], fn
      {_field, nil} -> nil
      {_field, false} -> nil
      {field, value} -> latest_task(repo, [{field, value}])
    end)
  end

  defp latest_task(repo, filter) do
    Repo.one(
      from t in Task,
        where: t.linked_repo_id == ^repo.id,
        where: ^filter,
        order_by: [desc: t.inserted_at],
        limit: 1
    )
  end

  # A comment is applied once, however many times it is delivered.
  defp once(repo, %Event{issue: issue, comment: %{id: id}}, fun) do
    state =
      Repo.get_by(IssueState, repo_id: repo.id, number: issue.number) ||
        %IssueState{repo_id: repo.id, number: issue.number}

    if to_string(id) in state.commands do
      {:ignored, "comando já aplicado"}
    else
      result = fun.()

      if match?({:processed, _, _}, result) do
        state
        |> Ecto.Changeset.change(commands: state.commands ++ [to_string(id)])
        |> Repo.insert_or_update!()
      end

      result
    end
  end

  defp apply_command(%Connection{api_mode: "runner"}, _repo, _task, _event, _parsed, _command),
    do: {:ignored, "comandos precisam que a plataforma chame o host"}

  defp apply_command(connection, repo, task, event, parsed, command) do
    with {:ok, client} <- client(connection),
         :ok <- Access.writer(client, repo, event.comment.author) do
      via = "#{provider_name(connection)}: #{event.comment.author}"

      case TaskSources.apply_command(task, parsed, via: via) do
        {:ok, _task} ->
          _ =
            client.provider.add_reaction(
              client,
              repo.full_name,
              {:comment, event.comment.id},
              "+1"
            )

          Audit.record(
            task.workspace_id,
            TaskSources.owner(task),
            "task.decided_from_host",
            task,
            %{
              "login" => event.comment.author,
              "action" => Atom.to_string(parsed.action)
            }
          )

          {:processed,
           "comando #{Commands.word(parsed.action)} aplicado por #{event.comment.author}",
           %{task_id: task.id}}

        {:error, reason} ->
          _ =
            client.provider.create_comment(
              client,
              repo.full_name,
              event.issue.number,
              "#{reason}\n\n#{Commands.help(command)}"
            )

          {:ignored, "o comando não vale agora: #{reason}"}
      end
    end
  end

  defp unknown(connection, repo, event, command) do
    with {:ok, client} <- client(connection),
         :ok <- Access.writer(client, repo, event.comment.author) do
      _ =
        client.provider.create_comment(
          client,
          repo.full_name,
          event.issue.number,
          Commands.help(command)
        )

      {:ignored, "comando desconhecido"}
    end
  end

  defp client(%Connection{api_mode: "runner"}),
    do: {:ignored, "comandos precisam que a plataforma chame o host"}

  defp client(connection), do: Access.client(connection)

  defp provider_name(%Connection{provider: "github"}), do: "GitHub"
  defp provider_name(%Connection{}), do: "Forgejo"
end
