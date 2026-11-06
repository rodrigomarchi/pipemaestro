defmodule PipeMaestro.Integrations.Ingest do
  @moduledoc """
  What the platform does with an event of a git host
  (`docs/specs/integracoes.md`, section 4).

  A webhook delivery is checked against the connection's secret, recorded
  (`PipeMaestro.Integrations.Delivery`, once per delivery id) and processed
  outside the request (`receive_webhook/4`): hosts give up on a slow answer
  and never retry. Processing (`process/2`) is a fixed sequence of steps,
  each of which may end it with the reason kept in the delivery's `outcome`:

   1. the event is one the platform uses;
   2. it was not caused by the connection's own bot;
   3. the repository is linked;
   4. the issue's state (`PipeMaestro.Integrations.IssueState`) tells the
      labels just added;
   5. a command in a comment on a task's issue or pull request, a review
     asking for changes or a merge go to the task
     (`PipeMaestro.Integrations.Conversation`); otherwise an enabled
     trigger matches;
   6. its author may fire it;
   7. the trigger has not reached its hourly limit;
   8. the issue has no task nor triage going on;
   9. read again from the host, the issue is still open;
  10. the project can take work (`PipeMaestro.Projects.health/2`): its
      runner offline is fine, the job waits for it; no runner, or the
      directory gone, is `waiting_runner`, for the reconciliation to try again;
  11. the triage or the task starts, the trigger's firing is kept and the
      issue is acknowledged.

  The steps of one issue run one delivery at a time. Options: `:presence`
  (`PipeMaestro.Runners.online_ids/2`).
  """

  import Ecto.Query

  require Logger

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.{Audit, Integrations, Pipelines, Projects, Proposals, Repo, Runners, Tasks}

  alias PipeMaestro.Integrations.{
    Access,
    Connection,
    Conversation,
    Delivery,
    Event,
    Feedback,
    GitHub,
    IssueState,
    LinkedRepo,
    Trigger
  }

  alias PipeMaestro.Workspaces.Workspace

  @doc """
  Takes a webhook delivery: checks its signature, records it and processes it
  in the background. `:duplicate` when the delivery was already taken.
  """
  @spec receive_webhook(String.t(), map(), binary(), keyword()) ::
          {:ok, Delivery.t()} | :duplicate | {:error, :not_found | :bad_signature | :bad_payload}
  def receive_webhook(connection_id, headers, raw_body, opts \\ []) do
    with {:ok, delivery} <- record_webhook(connection_id, headers, raw_body) do
      _ = Integrations.background(fn -> process(delivery, opts) end)
      {:ok, delivery}
    end
  end

  @doc """
  Takes a delivery of the platform's GitHub App, whose single webhook serves
  every installation (`PipeMaestro.Integrations.GitHub`): an installation
  removed or suspended stops its connections; any other event goes to the
  installation's connection, recorded and processed in the background.
  """
  @spec receive_app_webhook(map(), binary(), keyword()) ::
          {:ok, Delivery.t() | :installation | :ignored}
          | :duplicate
          | {:error, :not_found | :bad_signature | :bad_payload}
  def receive_app_webhook(headers, raw_body, opts \\ []) do
    with true <- GitHub.enabled?() || {:error, :not_found},
         true <- GitHub.app_signed?(headers, raw_body) || {:error, :bad_signature},
         {:ok, payload} <- decode(raw_body) do
      installation = to_string(get_in(payload, ["installation", "id"]) || "")

      app_event(
        GitHub.event_name(headers),
        payload["action"],
        installation,
        headers,
        payload,
        opts
      )
    end
  end

  defp app_event("installation", action, installation, _headers, _payload, _opts)
       when action in ["deleted", "suspend"] do
    Integrations.installation_gone(
      installation,
      "O GitHub App foi removido ou suspenso nessa conta."
    )

    {:ok, :installation}
  end

  defp app_event("installation", "unsuspend", installation, _headers, _payload, _opts) do
    with %Connection{} = connection <- Integrations.github_connection(installation),
         do: Integrations.check_connection(connection)

    {:ok, :installation}
  end

  defp app_event(event, _action, _installation, _headers, _payload, _opts)
       when event in ["installation", "installation_repositories", "ping"],
       do: {:ok, :ignored}

  defp app_event(event, _action, installation, headers, payload, opts) do
    with %Connection{} = connection <-
           Integrations.github_connection(installation) || {:ok, :ignored},
         {:ok, delivery} <-
           insert(
             connection,
             "webhook",
             GitHub.delivery_id(headers) || hash(JSON.encode!(payload)),
             event,
             payload
           ) do
      _ = Integrations.background(fn -> process(delivery, opts) end)
      {:ok, delivery}
    end
  end

  @doc "Checks and records a webhook delivery, without processing it."
  @spec record_webhook(String.t(), map(), binary()) ::
          {:ok, Delivery.t()} | :duplicate | {:error, :not_found | :bad_signature | :bad_payload}
  def record_webhook(connection_id, headers, raw_body) do
    # A GitHub connection takes only the App's webhook (receive_app_webhook/3).
    with %Connection{} = connection <-
           Integrations.get_connection(connection_id) || {:error, :not_found},
         true <- connection.provider == "forgejo" || {:error, :not_found},
         provider = Integrations.provider(connection),
         true <-
           provider.verify_signature(headers, raw_body, Connection.webhook_secret(connection)) ||
             {:error, :bad_signature},
         {:ok, payload} <- decode(raw_body) do
      external_id = provider.delivery_id(headers) || hash(raw_body)
      insert(connection, "webhook", external_id, provider.event_name(headers), payload)
    end
  end

  @doc """
  Records an event the platform found by itself (the reconciliation) and
  processes it now. `:duplicate` when the same event was taken before.
  """
  @spec ingest_event(Connection.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, Delivery.t()} | :duplicate
  def ingest_event(%Connection{} = connection, external_id, event_name, payload, opts \\ []) do
    with {:ok, delivery} <- insert(connection, "reconcile", external_id, event_name, payload) do
      {:ok, process(delivery, opts)}
    end
  end

  @doc "Processes a delivery again, as a new one recorded by `user`."
  @spec replay(Delivery.t(), User.t(), keyword()) :: {:ok, Delivery.t()}
  def replay(%Delivery{} = delivery, %User{} = user, opts \\ []) do
    connection = Repo.get!(Connection, delivery.connection_id)
    external_id = "replay:#{delivery.external_id}:#{System.unique_integer([:positive])}"
    {:ok, copy} = insert(connection, "replay", external_id, delivery.event, delivery.payload)

    Audit.record(connection.workspace_id, user, "integration.delivery_replayed", copy, %{
      "of" => delivery.id
    })

    {:ok, process(copy, opts)}
  end

  defp decode(raw_body) do
    case JSON.decode(raw_body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _invalid -> {:error, :bad_payload}
    end
  end

  defp hash(raw_body), do: :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)

  defp insert(connection, source, external_id, event_name, payload) do
    changes = %Delivery{
      workspace_id: connection.workspace_id,
      connection_id: connection.id,
      source: source,
      external_id: external_id,
      event: event_name,
      action: payload["action"],
      repo_full_name: payload |> get_in(["repository", "full_name"]) |> downcase(),
      issue_number: get_in(payload, ["issue", "number"]) || payload["number"],
      payload: Delivery.keep_payload(payload)
    }

    now = DateTime.utc_now()

    row =
      changes
      |> Map.take(Delivery.__schema__(:fields))
      |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

    case Repo.insert_all(Delivery, [row],
           on_conflict: :nothing,
           conflict_target: [:connection_id, :external_id],
           returning: true
         ) do
      {1, [delivery]} -> {:ok, delivery}
      {0, []} -> :duplicate
    end
  end

  @doc "Processes a recorded delivery and answers it as it ended."
  @spec process(Delivery.t(), keyword()) :: Delivery.t()
  def process(%Delivery{} = delivery, opts \\ []) do
    connection = Repo.get!(Connection, delivery.connection_id)
    provider = Integrations.provider(connection)
    headers = provider.stored_headers(delivery.event, delivery.external_id)

    case provider.parse_event(headers, delivery.payload) do
      {:ok, event} ->
        result =
          serialized(connection, event, fn -> handle_and_remember(connection, event, opts) end)

        finish(delivery, Atom.to_string(event.kind), result)

      {:ignore, reason} ->
        finish(delivery, nil, {:ignored, reason})
    end
  end

  defp handle_and_remember(connection, event, opts) do
    result = guarded(fn -> handle(connection, event, opts) end)
    remember(connection, event, result)
    result
  end

  # An error while processing ends the delivery as failed, logged and kept
  # with its message, for the reconciliation to try again.
  defp guarded(fun) do
    fun.()
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      {:failed, "erro ao processar: " <> Exception.message(exception)}
  end

  # Deliveries of the same issue wait for one another.
  defp serialized(connection, %Event{repo: repo, issue: %{number: number}}, fun)
       when is_binary(repo),
       do: :global.trans({{__MODULE__, connection.id, repo, number}, self()}, fun)

  defp serialized(_connection, _event, fun), do: fun.()

  defp finish(delivery, kind, result) do
    {status, outcome, links} =
      case result do
        {:processed, outcome, links} -> {"processed", outcome, links}
        {:ignored, reason} -> {"ignored", reason, %{}}
        {:waiting_runner, reason} -> {"waiting_runner", reason, %{}}
        {:failed, reason} -> {"failed", reason, %{}}
      end

    delivery =
      delivery
      |> Ecto.Changeset.change(
        Map.merge(links, %{
          status: status,
          outcome: outcome,
          kind: kind,
          attempts: delivery.attempts + 1,
          processed_at: DateTime.utc_now()
        })
      )
      |> Repo.update!()

    Integrations.broadcast_delivery(delivery)
    delivery
  end

  ## The steps

  defp handle(connection, %Event{} = event, opts) do
    with :ok <- not_own(connection, event),
         {:ok, repo} <- linked_repo(connection, event),
         :continue <- Conversation.handle(connection, repo, event),
         {:ok, added} <- observe(repo, event),
         {:ok, trigger, pipeline_id} <- match(repo, event, added),
         {:ok, client} <- Access.client(connection),
         :ok <- author_allowed(client, trigger, repo, event),
         :ok <- within_limit(repo, trigger),
         :ok <- not_active(repo, event),
         {:ok, issue} <- fresh_issue(client, connection, repo, event),
         :ok <- project_ready(connection, client, repo, issue, opts) do
      start(connection, client, repo, %{trigger | pipeline_id: pipeline_id}, issue)
    end
  end

  defp not_own(%Connection{bot_login: bot}, %Event{sender: sender})
       when is_binary(bot) and sender == bot,
       do: {:ignored, "evento do próprio bot"}

  defp not_own(_connection, _event), do: :ok

  defp linked_repo(connection, %Event{repo: full_name}) do
    query =
      from r in LinkedRepo,
        where: r.connection_id == ^connection.id and r.full_name == ^(full_name || ""),
        preload: [
          :project,
          triggers: ^from(t in Trigger, where: t.enabled, order_by: t.inserted_at)
        ]

    case Repo.one(query) do
      nil -> {:ignored, "repositório não vinculado"}
      repo -> {:ok, %{repo | connection: connection}}
    end
  end

  # The labels added since the issue was last seen.
  defp observe(repo, %Event{kind: kind, issue: issue})
       when kind in [:issue_opened, :issue_labels_changed],
       do: {:ok, issue.labels -- issue_state(repo, issue.number).labels}

  defp observe(_repo, _event), do: {:ok, []}

  defp issue_state(repo, number) do
    Repo.get_by(IssueState, repo_id: repo.id, number: number) ||
      %IssueState{repo_id: repo.id, number: number}
  end

  # Keeps the issue's labels, unless the delivery will be tried again: then
  # the label just added must still look new.
  defp remember(_connection, _event, {status, _reason}) when status in [:waiting_runner, :failed],
    do: :ok

  defp remember(_connection, %Event{issue: nil}, _result), do: :ok

  defp remember(connection, %Event{issue: issue} = event, _result) do
    with {:ok, repo} <- linked_repo(connection, event) do
      repo
      |> issue_state(issue.number)
      |> Ecto.Changeset.change(labels: issue.labels, seen_updated_at: issue.updated_at)
      |> Repo.insert_or_update!()
    end

    :ok
  end

  defp match(repo, event, added) do
    repo.triggers
    |> Enum.find_value(fn trigger -> matches(trigger, event, added) end)
    |> case do
      nil -> {:ignored, "nenhum gatilho casou"}
      {:ok, trigger, pipeline} -> {:ok, trigger, pipeline}
      {:ignored, reason} -> {:ignored, reason}
    end
  end

  defp matches(%Trigger{kind: "label", label: label} = trigger, %Event{kind: kind}, added)
       when kind in [:issue_opened, :issue_labels_changed] do
    if label in added, do: {:ok, trigger, trigger.pipeline_id}
  end

  defp matches(
         %Trigger{kind: "comment", command: command} = trigger,
         %Event{kind: :issue_comment, issue: %{is_pull: false}} = event,
         _added
       ) do
    first_line =
      event.comment.body
      |> String.trim_leading()
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.trim()

    case String.split(first_line, ~r/\s+/, parts: 2) do
      [^command] -> {:ok, trigger, trigger.pipeline_id}
      [^command, name] -> named_pipeline(trigger, name)
      _other -> nil
    end
  end

  defp matches(
         %Trigger{kind: "opened"} = trigger,
         %Event{kind: :issue_opened, issue: %{is_pull: false}},
         _added
       ),
       do: {:ok, trigger, trigger.pipeline_id}

  defp matches(_trigger, _event, _added), do: nil

  defp named_pipeline(trigger, name) do
    wanted = String.downcase(String.trim(name))

    case Enum.find(
           Pipelines.list_pipelines(%Workspace{id: trigger.workspace_id}),
           &(String.downcase(&1.name) == wanted)
         ) do
      nil -> {:ignored, "o pipeline #{name} não existe neste workspace"}
      pipeline -> {:ok, trigger, pipeline.id}
    end
  end

  # Whoever caused the event must have write access, unless the trigger takes
  # any author. A label is checked too: an issue template adds labels for
  # anyone who opens an issue. A label the reconciliation found has no known
  # sender; its issue's author stands for it.
  defp author_allowed(_client, %Trigger{author_policy: "anyone"}, _repo, _event), do: :ok

  defp author_allowed(client, %Trigger{kind: "label"}, repo, event),
    do: Access.writer(client, repo, event.sender || event.issue.author)

  defp author_allowed(client, _trigger, repo, event) do
    author = if event.comment, do: event.comment.author, else: event.issue.author
    Access.writer(client, repo, author)
  end

  defp within_limit(repo, trigger) do
    since = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()

    fired =
      Repo.aggregate(
        from(i in IssueState,
          where: i.repo_id == ^repo.id,
          where: fragment("(?->?->>'at') > ?", i.fired, ^trigger.id, ^since)
        ),
        :count
      )

    if fired >= trigger.max_per_hour,
      do: {:ignored, "o gatilho chegou ao limite por hora"},
      else: :ok
  end

  defp not_active(repo, %Event{issue: issue}) do
    workspace = %Workspace{id: repo.workspace_id}

    if Tasks.active_for_issue?(workspace, issue.url) or Proposals.triaging?(workspace, issue.url),
      do: {:ignored, "a issue já tem uma tarefa ou triagem em andamento"},
      else: :ok
  end

  # Deliveries may come out of order: the issue is read again.
  defp fresh_issue(client, %Connection{api_mode: "control_plane"}, repo, %Event{issue: issue}) do
    case client.provider.get_issue(client, repo.full_name, issue.number) do
      {:ok, %{state: "closed"}} ->
        {:ignored, "a issue foi fechada"}

      {:ok, fresh} ->
        {:ok, fresh}

      {:error, error} ->
        {:failed, "não foi possível ler a issue: " <> Integrations.describe(error)}
    end
  end

  defp fresh_issue(_client, _connection, _repo, %Event{issue: issue}), do: {:ok, issue}

  # The project decides where the work runs (its runner and directory). A
  # runner offline is no error: the job waits for it. A project without a
  # runner, or whose runner no longer offers the directory, takes no work: the
  # delivery waits, for the reconciliation to try again once it is fixed.
  defp project_ready(_connection, _client, %LinkedRepo{project: nil}, _issue, _opts),
    do: {:ignored, "o repositório não está ligado a um projeto"}

  defp project_ready(connection, client, repo, issue, opts) do
    project = repo.project

    waiting =
      case Projects.health(project, Runners.online_ids(repo.workspace_id, opts)) do
        healthy when healthy in [:ok, :runner_offline] -> nil
        :needs_runner -> "o projeto #{project.name} não tem um runner"
        :directory_gone -> "o runner do projeto não oferece mais a pasta #{project.directory}"
      end

    if waiting do
      note(
        connection,
        client,
        repo,
        issue,
        "Esperando: #{waiting}; a issue segue assim que isso for resolvido."
      )

      {:waiting_runner, waiting}
    else
      :ok
    end
  end

  defp note(%Connection{api_mode: "control_plane"}, client, repo, issue, text),
    do: Feedback.status_note(client, repo, issue.number, text)

  defp note(_connection, _client, _repo, _issue, _text), do: :ok

  defp start(connection, client, repo, trigger, issue) do
    workspace = Repo.get!(Workspace, repo.workspace_id)

    attrs = %{
      "title" => issue.title,
      "body" => issue.body,
      "html_url" => issue.url,
      "number" => issue.number
    }

    result =
      case trigger.mode do
        "task" -> Tasks.create_from_linked_issue(workspace, repo, trigger, attrs)
        _triage -> Proposals.triage_linked_issue(workspace, repo, trigger, attrs)
      end

    case result do
      {:ok, %Tasks.Task{id: id}} ->
        fired(repo, issue, trigger, %{"task_id" => id})
        Feedback.acknowledge(connection, client, repo, issue.number, :queued)
        {:processed, "tarefa criada", %{task_id: id}}

      {:ok, job} ->
        fired(repo, issue, trigger, %{"proposal_job_id" => job.id})
        Feedback.acknowledge(connection, client, repo, issue.number, :triaging)
        {:processed, "triagem pedida ao agente", %{proposal_job_id: job.id}}

      {:error, :already_triaging} ->
        {:ignored, "a issue já tem uma tarefa ou triagem em andamento"}

      {:error, :no_acting_user} ->
        {:failed, "o gatilho não tem em nome de quem criar a tarefa"}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:failed, "não foi possível criar: " <> inspect(changeset.errors)}
    end
  end

  defp fired(repo, issue, trigger, link) do
    state = issue_state(repo, issue.number)
    entry = Map.put(link, "at", DateTime.utc_now() |> DateTime.to_iso8601())

    state
    |> Ecto.Changeset.change(fired: Map.put(state.fired, trigger.id, entry))
    |> Repo.insert_or_update!()
  end

  defp downcase(nil), do: nil
  defp downcase(text), do: String.downcase(text)
end
