defmodule PipeMaestro.Integrations.Conversation do
  @moduledoc """
  What people say to a task on its git host (`docs/specs/integracoes.md`,
  sections 6 and 7):

  - a command in a comment on the task's issue or pull request
    (`PipeMaestro.Integrations.Commands`), from someone with write access,
    goes to the same functions as the task's screen, on behalf of whoever
    the task belongs to; the host's login is kept in the audit. An applied
    command gets a 👍; one that does not apply gets an answer with the
    commands that do;
  - a review asking for changes on the pull request of a finished task
    becomes the stage "Correção N";
  - the pull request merged is told on the issue.

  Anything else goes on to the triggers (`:continue`). Commands need the
  platform to call the host (`api_mode` `"control_plane"`).
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.{Audit, Integrations, Repo, Tasks}

  alias PipeMaestro.Integrations.{
    Commands,
    Connection,
    Credentials,
    Event,
    Feedback,
    IssueState,
    LinkedRepo
  }

  alias PipeMaestro.Tasks.Task

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

  def handle(_connection, repo, %Event{kind: :pr_review, review: %{state: :rejected}} = event) do
    case task_for(repo, event) do
      nil ->
        :continue

      %Task{status: status} = task when status in [:succeeded, :canceled] ->
        prompt =
          "Pedido de mudanças no review do pull request, por @#{event.sender}:\n\n#{event.review.body}"

        case Tasks.correct(task, prompt, by: owner(task)) do
          {:ok, task} -> {:processed, "correção pedida pelo review", %{task_id: task.id}}
          {:error, reason} -> {:ignored, "a correção não pôde começar (#{reason})"}
        end

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

  def handle(_connection, _repo, _event), do: :continue

  # The repository's comment command, or the default one.
  defp command(%LinkedRepo{triggers: triggers}) when is_list(triggers) do
    Enum.find_value(triggers, @default_command, &(&1.kind == "comment" && &1.command))
  end

  defp command(_repo), do: @default_command

  # The task of the issue (its latest), or of the pull request (by branch).
  defp task_for(repo, %Event{issue: %{is_pull: false, number: number}}) do
    Repo.one(
      from t in Task,
        where: t.linked_repo_id == ^repo.id and t.issue_number == ^number,
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
         :ok <- writer(client, repo, event.comment.author) do
      case run(task, parsed) do
        {:ok, _task} ->
          _ =
            client.provider.add_reaction(
              client,
              repo.full_name,
              {:comment, event.comment.id},
              "+1"
            )

          Audit.record(task.workspace_id, owner(task), "task.decided_from_host", task, %{
            "login" => event.comment.author,
            "action" => Atom.to_string(parsed.action)
          })

          {:processed,
           "comando #{Commands.word(parsed.action)} aplicado por #{event.comment.author}",
           %{task_id: task.id}}

        error ->
          reason = reason(error)

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
         :ok <- writer(client, repo, event.comment.author) do
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

  defp client(connection) do
    case Credentials.client(connection) do
      {:ok, client} -> {:ok, client}
      {:error, message} -> {:failed, "sem acesso ao host: " <> message}
    end
  end

  defp writer(client, repo, login) do
    case client.provider.permission(client, repo.full_name, login) do
      {:ok, permission} when permission in [:admin, :write] ->
        :ok

      {:ok, _none} ->
        {:ignored, "o autor não tem permissão de escrita"}

      {:error, error} ->
        {:failed, "não foi possível ver a permissão do autor: " <> Integrations.describe(error)}
    end
  end

  defp run(task, %{action: :advance, text: text}),
    do: Tasks.advance(task, blank(text), by: owner(task))

  defp run(task, %{action: :retry, text: text}),
    do: Tasks.retry_stage(task, blank(text), by: owner(task))

  defp run(task, %{action: :pause}), do: Tasks.request_pause(task)
  defp run(task, %{action: :cancel}), do: Tasks.cancel_task(task, by: owner(task))

  defp run(task, %{action: :correct, text: text}),
    do: Tasks.correct(task, blank(text), by: owner(task))

  defp run(task, %{action: :answer, text: text}) do
    questions = get_in(task.decision_questionnaire || %{}, ["perguntas"]) || []
    Tasks.answer(task, Commands.answers(text, questions), nil, by: owner(task))
  end

  defp owner(%Task{created_by_user_id: id}), do: Repo.get(User, id)

  defp blank(text), do: if(String.trim(text) == "", do: nil, else: text)

  defp reason({:error, :invalid_answers, message}), do: "As respostas não valem: #{message}"
  defp reason({:error, :not_awaiting}), do: "A tarefa não espera uma decisão agora."
  defp reason({:error, :not_running}), do: "A tarefa não está rodando."
  defp reason({:error, :finished}), do: "A tarefa já terminou."

  defp reason({:error, :active}),
    do: "A tarefa ainda está em andamento; corrija quando ela terminar."

  defp reason({:error, :blank}), do: "Diga o que corrigir depois do comando."
  defp reason({:error, other}), do: "Não foi possível (#{inspect(other)})."
end
