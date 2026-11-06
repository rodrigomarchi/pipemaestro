defmodule PipeMaestro.Integrations do
  @moduledoc """
  Integrations with git hosts (Forgejo, GitHub): a workspace connects a host
  (`PipeMaestro.Integrations.Connection`), links its repositories to projects
  (`PipeMaestro.Integrations.LinkedRepo`) and says what starts a task from an
  issue (`PipeMaestro.Integrations.Trigger`). The rules are in
  `docs/specs/integracoes.md`; the decisions in ADR 0034.

  Who may call these is the screens' concern (`:manage_integrations`,
  `PipeMaestro.Authorization`); every change is audited. Calls to the host
  go through the connection's provider (`PipeMaestro.Integrations.Provider`)
  with its credential (`PipeMaestro.Integrations.Credentials`). The
  webhook's URL is the web app's, so it is passed in.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Audit
  alias PipeMaestro.Integrations.{Connection, Credentials, IssueUrl, Labels, LinkedRepo, Trigger}
  alias PipeMaestro.{Pipelines, Repo, Workspaces}
  alias PipeMaestro.Projects.Project
  alias PipeMaestro.Workspaces.Workspace

  @doc "The pattern of an issue's link on any host."
  @spec issue_url_regex() :: Regex.t()
  defdelegate issue_url_regex, to: IssueUrl, as: :regex

  @doc "The path of a connection's webhook, under the platform's URL."
  @spec webhook_path(Connection.t()) :: String.t()
  def webhook_path(%Connection{id: id}), do: "/api/integrations/#{id}/webhook"

  ## Connections

  @doc "The workspace's connections, by name."
  @spec list_connections(Workspace.t()) :: [Connection.t()]
  def list_connections(%Workspace{id: workspace_id}),
    do: Repo.all(from c in Connection, where: c.workspace_id == ^workspace_id, order_by: c.name)

  @doc "How many repositories each of the workspace's connections links, by connection id."
  @spec repo_counts(Workspace.t()) :: %{Ecto.UUID.t() => non_neg_integer()}
  def repo_counts(%Workspace{id: workspace_id}) do
    from(r in LinkedRepo,
      where: r.workspace_id == ^workspace_id,
      group_by: r.connection_id,
      select: {r.connection_id, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "One of the workspace's connections. Raises when it is not the workspace's."
  @spec get_connection!(Workspace.t(), Ecto.UUID.t()) :: Connection.t()
  def get_connection!(%Workspace{id: workspace_id}, id),
    do: Repo.get_by!(Connection, id: id, workspace_id: workspace_id)

  @doc "A connection by id, of any workspace (the webhook finds it by its URL)."
  @spec get_connection(Ecto.UUID.t()) :: Connection.t() | nil
  def get_connection(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Connection, uuid)
      :error -> nil
    end
  end

  @doc "A changeset for the connection's form."
  @spec change_connection(Connection.t(), map()) :: Changeset.t()
  def change_connection(%Connection{} = connection, attrs \\ %{}),
    do: Connection.changeset(connection, attrs)

  @doc """
  Creates a connection and, with a token, checks it right away
  (`check_connection/1`). An OAuth connection waits, `"pending"`, for someone
  to sign in.
  """
  @spec create_connection(Workspace.t(), User.t(), map()) ::
          {:ok, Connection.t()} | {:error, Changeset.t()}
  def create_connection(%Workspace{} = workspace, %User{} = user, attrs) do
    with {:ok, connection} <-
           %Connection{workspace_id: workspace.id, connected_by_id: user.id}
           |> Connection.changeset(attrs)
           |> Repo.insert() do
      Audit.record(workspace.id, user, "integration.connected", connection, %{
        "provider" => connection.provider
      })

      {:ok, maybe_check(connection)}
    end
  end

  @doc """
  Changes a connection, checking it again when the address or the credential
  changed. The runner mode is refused while a trigger needs the API.
  """
  @spec update_connection(Connection.t(), User.t(), map()) ::
          {:ok, Connection.t()} | {:error, Changeset.t()}
  def update_connection(%Connection{} = connection, %User{} = user, attrs) do
    changeset =
      connection
      |> Connection.changeset(attrs)
      |> validate_api_mode(connection)

    recheck? =
      Enum.any?(
        [:base_url, :encrypted_credentials, :auth_kind],
        &Changeset.changed?(changeset, &1)
      )

    with {:ok, updated} <- Repo.update(changeset) do
      Audit.record(updated.workspace_id, user, "integration.updated", updated)
      {:ok, if(recheck?, do: maybe_check(updated), else: updated)}
    end
  end

  defp validate_api_mode(changeset, connection) do
    needs_api =
      from(t in Trigger,
        join: r in assoc(t, :repo),
        where: r.connection_id == ^connection.id and t.kind != "label"
      )

    if Changeset.get_change(changeset, :api_mode) == "runner" and Repo.exists?(needs_api),
      do:
        Changeset.add_error(
          changeset,
          :api_mode,
          "remova antes os gatilhos por comentário e por issue nova"
        ),
      else: changeset
  end

  @doc "Removes a connection, and the webhooks the platform created for it."
  @spec delete_connection(Connection.t(), User.t()) :: :ok
  def delete_connection(%Connection{} = connection, %User{} = user) do
    connection |> list_repos() |> Enum.each(&remove_webhook(connection, &1))
    Repo.delete!(connection)
    Audit.record(connection.workspace_id, user, "integration.removed", connection)
    :ok
  end

  @doc "Asks the host who the credential is and its version, and records the answer."
  @spec check_connection(Connection.t()) :: Connection.t()
  def check_connection(%Connection{} = connection) do
    result =
      with {:ok, client} <- Credentials.client(connection),
           {:ok, me} <- whoami(client) do
        version =
          case client.provider.version(client) do
            {:ok, version} -> version
            {:error, _} -> nil
          end

        {:ok, Map.put(me, :version, version)}
      end

    connection
    |> Connection.check_changeset(result, DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp whoami(client) do
    case client.provider.whoami(client) do
      {:ok, me} -> {:ok, me}
      {:error, error} -> {:error, describe(error)}
    end
  end

  defp maybe_check(%Connection{auth_kind: "oauth"} = connection) do
    if Connection.credentials(connection) == %{},
      do: connection,
      else: check_connection(connection)
  end

  defp maybe_check(connection), do: check_connection(connection)

  @doc """
  A new secret for the connection's webhook, written to the webhooks the
  platform created (`webhook_url` is the platform's URL of it).
  """
  @spec rotate_webhook_secret(Connection.t(), User.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, String.t()}
  def rotate_webhook_secret(%Connection{} = connection, %User{} = user, webhook_url) do
    connection = connection |> Connection.webhook_secret_changeset() |> Repo.update!()
    Audit.record(connection.workspace_id, user, "integration.webhook_secret_rotated", connection)
    secret = Connection.webhook_secret(connection)

    with {:ok, client} <- Credentials.client(connection) do
      failed =
        for %LinkedRepo{webhook_status: "managed"} = repo <- list_repos(connection),
            client.provider.update_webhook(
              client,
              repo.full_name,
              repo.webhook_id,
              webhook_url,
              secret
            ) != :ok,
            do: repo.full_name

      if failed == [],
        do: {:ok, connection},
        else: {:error, "não foi possível atualizar o webhook de " <> Enum.join(failed, ", ")}
    end
  end

  ## Repositories

  @doc "The repositories the connection's credential reaches, matching `query`."
  @spec available_repos(Connection.t(), String.t(), pos_integer()) ::
          {:ok, [map()], boolean()} | {:error, String.t()}
  def available_repos(%Connection{} = connection, query, page \\ 1) do
    with {:ok, client} <- Credentials.client(connection) do
      case client.provider.list_repos(client, query, page) do
        {:ok, repos, more?} -> {:ok, repos, more?}
        {:error, error} -> {:error, describe(error)}
      end
    end
  end

  @doc "The connection's linked repositories, by name, with their projects and triggers."
  @spec list_repos(Connection.t()) :: [LinkedRepo.t()]
  def list_repos(%Connection{id: connection_id}) do
    Repo.all(
      from r in LinkedRepo,
        where: r.connection_id == ^connection_id,
        order_by: r.full_name,
        preload: [:project, :triggers]
    )
  end

  @doc "One of the connection's repositories. Raises when it is not the connection's."
  @spec get_repo!(Connection.t(), Ecto.UUID.t()) :: LinkedRepo.t()
  def get_repo!(%Connection{id: connection_id}, id) do
    LinkedRepo
    |> Repo.get_by!(id: id, connection_id: connection_id)
    |> Repo.preload([
      :project,
      :connection,
      triggers: from(t in Trigger, order_by: t.inserted_at)
    ])
  end

  @doc "A changeset for the repository's form."
  @spec change_repo(LinkedRepo.t(), map()) :: Changeset.t()
  def change_repo(%LinkedRepo{} = repo, attrs \\ %{}), do: LinkedRepo.changeset(repo, attrs)

  @doc """
  Links a repository of the connection (`full_name`) to a project
  (`project_id`): reads it from the host, creates the platform's labels it
  lacks and its webhook at `webhook_url`. Without the right to create the
  webhook, the repository is linked anyway, waiting for a manual one.
  """
  @spec link_repo(Connection.t(), User.t(), map(), String.t()) ::
          {:ok, LinkedRepo.t()} | {:error, Changeset.t()}
  def link_repo(%Connection{} = connection, %User{} = user, attrs, webhook_url) do
    changeset =
      %LinkedRepo{connection_id: connection.id, workspace_id: connection.workspace_id}
      |> LinkedRepo.changeset(attrs)
      |> validate_project(connection.workspace_id)
      |> Map.put(:action, :insert)

    with true <- changeset.valid? || {:error, changeset},
         {:ok, client} <- client_for(connection, changeset),
         {:ok, host_repo} <- host_repo(client, changeset),
         {:ok, repo} <-
           changeset
           |> Changeset.change(
             external_id: to_string(host_repo.id),
             default_branch: host_repo.default_branch
           )
           |> Repo.insert() do
      _ =
        client.provider.ensure_labels(client, repo.full_name, Labels.defaults(repo.label_prefix))

      repo = create_webhook(client, connection, repo, webhook_url)
      audit_repo(repo, user, "integration.repo_linked")
      {:ok, repo}
    end
  end

  defp client_for(connection, changeset) do
    case Credentials.client(connection) do
      {:ok, client} -> {:ok, client}
      {:error, message} -> {:error, Changeset.add_error(changeset, :full_name, message)}
    end
  end

  defp host_repo(client, changeset) do
    case client.provider.get_repo(client, Changeset.get_field(changeset, :full_name)) do
      {:ok, host_repo} ->
        {:ok, host_repo}

      {:error, error} ->
        message = "o host não encontrou o repositório: " <> describe(error)
        {:error, Changeset.add_error(changeset, :full_name, message)}
    end
  end

  defp audit_repo(repo, user, action),
    do: Audit.record(repo.workspace_id, user, action, repo, %{"repo" => repo.full_name})

  defp create_webhook(client, connection, repo, webhook_url) do
    attrs =
      case client.provider.create_webhook(
             client,
             repo.full_name,
             webhook_url,
             Connection.webhook_secret(connection)
           ) do
        {:ok, id} -> %{webhook_id: id, webhook_status: "managed"}
        {:error, %{status: status}} when status in [401, 403, 404] -> %{webhook_status: "manual"}
        {:error, _error} -> %{webhook_status: "failed"}
      end

    repo |> LinkedRepo.host_changeset(attrs) |> Repo.update!()
  end

  defp validate_project(changeset, workspace_id) do
    Changeset.validate_change(changeset, :project_id, fn :project_id, id ->
      if Repo.exists?(from p in Project, where: p.id == ^id and p.workspace_id == ^workspace_id),
        do: [],
        else: [project_id: "escolha um projeto deste workspace"]
    end)
  end

  @doc "Changes the repository's project or label prefix, creating the new labels."
  @spec update_repo(LinkedRepo.t(), User.t(), map()) ::
          {:ok, LinkedRepo.t()} | {:error, Changeset.t()}
  def update_repo(%LinkedRepo{} = repo, %User{} = user, attrs) do
    changeset =
      repo
      |> LinkedRepo.changeset(Map.drop(attrs, ["full_name", :full_name]))
      |> validate_project(repo.workspace_id)

    with {:ok, updated} <- Repo.update(changeset) do
      if Changeset.changed?(changeset, :label_prefix), do: ensure_labels(updated)
      audit_repo(updated, user, "integration.repo_updated")
      {:ok, Repo.preload(updated, [:project], force: true)}
    end
  end

  defp ensure_labels(repo) do
    connection = Repo.get!(Connection, repo.connection_id)

    with {:ok, client} <- Credentials.client(connection),
         do:
           client.provider.ensure_labels(
             client,
             repo.full_name,
             Labels.defaults(repo.label_prefix)
           )
  end

  @doc "Unlinks a repository, removing the webhook the platform created."
  @spec unlink_repo(LinkedRepo.t(), User.t()) :: :ok
  def unlink_repo(%LinkedRepo{} = repo, %User{} = user) do
    connection = Repo.get!(Connection, repo.connection_id)
    remove_webhook(connection, repo)
    Repo.delete!(repo)
    audit_repo(repo, user, "integration.repo_unlinked")
    :ok
  end

  defp remove_webhook(connection, %LinkedRepo{webhook_status: "managed", webhook_id: id} = repo)
       when is_binary(id) do
    with {:ok, client} <- Credentials.client(connection),
         do: client.provider.delete_webhook(client, repo.full_name, id)

    :ok
  end

  defp remove_webhook(_connection, _repo), do: :ok

  ## Triggers

  @doc "The repository's triggers, oldest first."
  @spec list_triggers(LinkedRepo.t()) :: [Trigger.t()]
  def list_triggers(%LinkedRepo{id: repo_id}),
    do: Repo.all(from t in Trigger, where: t.repo_id == ^repo_id, order_by: t.inserted_at)

  @doc "A new trigger for the form: the repository's label and command, on behalf of `user`."
  @spec new_trigger(LinkedRepo.t(), User.t()) :: Trigger.t()
  def new_trigger(%LinkedRepo{} = repo, %User{} = user),
    do: %Trigger{label: repo.label_prefix, command: "/pipemaestro", acting_user_id: user.id}

  @doc "A changeset for the trigger's form."
  @spec change_trigger(LinkedRepo.t(), Trigger.t(), map()) :: Changeset.t()
  def change_trigger(%LinkedRepo{} = repo, %Trigger{} = trigger, attrs \\ %{}),
    do: Trigger.changeset(trigger, attrs, api_mode(repo))

  @doc "Saves a trigger of the repository, new or changed."
  @spec save_trigger(LinkedRepo.t(), User.t(), Trigger.t(), map()) ::
          {:ok, Trigger.t()} | {:error, Changeset.t()}
  def save_trigger(%LinkedRepo{} = repo, %User{} = user, %Trigger{} = trigger, attrs) do
    workspace = Repo.get!(Workspace, repo.workspace_id)

    trigger = %{
      trigger
      | repo_id: repo.id,
        workspace_id: repo.workspace_id,
        acting_user_id: trigger.acting_user_id || user.id
    }

    trigger
    |> Trigger.changeset(attrs, api_mode(repo))
    |> Changeset.validate_change(:pipeline_id, fn :pipeline_id, id ->
      if Pipelines.get_pipeline(workspace.id, id),
        do: [],
        else: [pipeline_id: "escolha um pipeline deste workspace"]
    end)
    |> Changeset.validate_change(:acting_user_id, fn :acting_user_id, id ->
      member = Repo.get(User, id)

      if member && Workspaces.member?(workspace, member),
        do: [],
        else: [acting_user_id: "escolha alguém do workspace"]
    end)
    |> Repo.insert_or_update()
    |> case do
      {:ok, saved} ->
        Audit.record(workspace, user, "integration.trigger_saved", saved, %{
          "repo" => repo.full_name,
          "kind" => saved.kind
        })

        {:ok, saved}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Removes a trigger."
  @spec delete_trigger(Trigger.t(), User.t()) :: :ok
  def delete_trigger(%Trigger{} = trigger, %User{} = user) do
    Repo.delete!(trigger)

    Audit.record(trigger.workspace_id, user, "integration.trigger_removed", trigger, %{
      "kind" => trigger.kind
    })

    :ok
  end

  defp api_mode(%LinkedRepo{connection: %Connection{api_mode: mode}}), do: mode

  defp api_mode(%LinkedRepo{connection_id: id}),
    do: Repo.one!(from c in Connection, where: c.id == ^id, select: c.api_mode)

  @doc "A host error, for a person."
  @spec describe(%{status: pos_integer() | nil, message: String.t()}) :: String.t()
  def describe(%{status: nil, message: message}), do: "sem resposta do host (#{message})"
  def describe(%{status: status, message: message}), do: "HTTP #{status}: #{message}"
end
