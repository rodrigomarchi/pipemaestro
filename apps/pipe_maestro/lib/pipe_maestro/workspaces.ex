defmodule PipeMaestro.Workspaces do
  @moduledoc """
  Workspaces (customer companies) and who belongs to them. A user may belong to
  several workspaces; membership is the only link between the two.
  """

  import Ecto.Query

  alias PipeMaestro.Accounts.User
  alias PipeMaestro.Repo
  alias PipeMaestro.Workspaces.{Membership, Plan, Workspace}

  @doc "Every workspace, by name, with `member_count` filled in."
  @spec list_workspaces() :: [Workspace.t()]
  def list_workspaces do
    Repo.all(
      from w in Workspace,
        left_join: m in assoc(w, :memberships),
        group_by: w.id,
        order_by: [asc: w.name],
        select_merge: %{member_count: count(m.id)}
    )
  end

  @doc "The workspace with `id`, with its `owner`. Raises when there is none."
  @spec get_workspace!(Ecto.UUID.t()) :: Workspace.t()
  def get_workspace!(id), do: Workspace |> Repo.get!(id) |> Repo.preload(:owner)

  @doc """
  The workspaces `user` belongs to, by name; with `role: :admin`, only those
  where they are an admin.
  """
  @spec list_workspaces_for_user(User.t(), keyword()) :: [Workspace.t()]
  def list_workspaces_for_user(%User{id: user_id}, opts \\ []) do
    query =
      from w in Workspace,
        join: m in assoc(w, :memberships),
        where: m.user_id == ^user_id,
        order_by: [asc: w.name]

    query =
      case opts[:role] do
        nil -> query
        role -> where(query, [_w, m], m.role == ^role)
      end

    Repo.all(query)
  end

  @doc "The workspace with `slug`, or `nil`."
  @spec get_workspace_by_slug(String.t()) :: Workspace.t() | nil
  def get_workspace_by_slug(slug) when is_binary(slug), do: Repo.get_by(Workspace, slug: slug)

  @doc "The workspace with `slug` if `user` belongs to it, `nil` otherwise."
  @spec get_workspace_for_user(User.t(), String.t()) :: Workspace.t() | nil
  def get_workspace_for_user(%User{id: user_id}, slug) when is_binary(slug) do
    Repo.one(
      from w in Workspace,
        join: m in assoc(w, :memberships),
        where: w.slug == ^slug and m.user_id == ^user_id
    )
  end

  @doc "Whether `user` belongs to `workspace`."
  @spec member?(Workspace.t(), User.t()) :: boolean()
  def member?(%Workspace{id: workspace_id}, %User{id: user_id}) do
    Repo.exists?(
      from m in Membership, where: m.workspace_id == ^workspace_id and m.user_id == ^user_id
    )
  end

  @doc "Creates a workspace."
  @spec create_workspace(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(attrs), do: %Workspace{} |> Workspace.changeset(attrs) |> Repo.insert()

  @doc """
  Creates a Free beta workspace for `user`, who becomes its owner and admin
  (ADR 0058). Only the name and address come from `attrs`; the limits are the
  plan's. Past the plan's number of workspaces per owner, nothing is created.
  """
  @spec create_owned_workspace(User.t(), map()) ::
          {:ok, Workspace.t()} | {:error, :limit_reached | Ecto.Changeset.t()}
  def create_owned_workspace(%User{id: user_id} = user, attrs) do
    limits = Plan.free_beta()

    Repo.transact(fn ->
      # Holding the owner's row makes two creations at once count one after the other.
      Repo.one!(from u in User, where: u.id == ^user_id, lock: "FOR UPDATE", select: u.id)

      if count_owned_workspaces(user) >= limits.workspaces_per_owner,
        do: {:error, :limit_reached},
        else: insert_owned(user, attrs, limits)
    end)
  end

  defp insert_owned(user, attrs, limits) do
    workspace =
      struct!(
        Workspace,
        limits
        |> Map.delete(:workspaces_per_owner)
        |> Map.merge(%{plan: :free_beta, owner_id: user.id})
      )

    with {:ok, workspace} <- workspace |> Workspace.owned_changeset(attrs) |> Repo.insert(),
         {:ok, _membership} <- add_member(workspace, user, :admin) do
      {:ok, workspace}
    end
  end

  @doc "How many workspaces `user` created through self-serve sign-up."
  @spec count_owned_workspaces(User.t()) :: non_neg_integer()
  def count_owned_workspaces(%User{id: user_id}) do
    Repo.aggregate(from(w in Workspace, where: w.owner_id == ^user_id), :count)
  end

  @doc "Whether `user` may still create a workspace of their own."
  @spec can_create_workspace?(User.t()) :: boolean()
  def can_create_workspace?(%User{} = user) do
    count_owned_workspaces(user) < Plan.free_beta().workspaces_per_owner
  end

  @doc "A changeset for the form where someone creates their own workspace."
  @spec change_owned_workspace(map()) :: Ecto.Changeset.t()
  def change_owned_workspace(attrs \\ %{}), do: Workspace.owned_changeset(%Workspace{}, attrs)

  @doc "Renames a workspace or changes its slug."
  @spec update_workspace(Workspace.t(), map()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def update_workspace(%Workspace{} = workspace, attrs) do
    workspace |> Workspace.changeset(attrs) |> Repo.update()
  end

  @doc "A changeset for the workspace form."
  @spec change_workspace(Workspace.t(), map()) :: Ecto.Changeset.t()
  def change_workspace(%Workspace{} = workspace, attrs \\ %{}) do
    Workspace.changeset(workspace, attrs)
  end

  @doc "The members of `workspace`, by name."
  @spec list_members(Workspace.t()) :: [User.t()]
  def list_members(%Workspace{id: workspace_id}) do
    Repo.all(
      from u in User,
        join: m in assoc(u, :memberships),
        where: m.workspace_id == ^workspace_id,
        order_by: [asc: u.name]
    )
  end

  @doc "Users who do not belong to `workspace` yet, by name."
  @spec list_non_members(Workspace.t()) :: [User.t()]
  def list_non_members(%Workspace{id: workspace_id}) do
    members = from m in Membership, where: m.workspace_id == ^workspace_id, select: m.user_id

    Repo.all(from u in User, where: u.id not in subquery(members), order_by: [asc: u.name])
  end

  @doc """
  Adds `user` to `workspace` with `role`; by default the first member becomes
  an admin and the next ones members.
  """
  @spec add_member(Workspace.t(), User.t(), Membership.role() | nil) ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def add_member(%Workspace{id: workspace_id}, %User{id: user_id}, role \\ nil) do
    role =
      role ||
        if Repo.exists?(from m in Membership, where: m.workspace_id == ^workspace_id),
          do: :member,
          else: :admin

    %Membership{}
    |> Membership.changeset(%{workspace_id: workspace_id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  @doc "`user`'s role in `workspace`, or `nil` when not a member."
  @spec role(Workspace.t(), User.t()) :: Membership.role() | nil
  def role(%Workspace{id: workspace_id}, %User{id: user_id}) do
    Repo.one(
      from m in Membership,
        where: m.workspace_id == ^workspace_id and m.user_id == ^user_id,
        select: m.role
    )
  end

  @doc "Changes a member's role."
  @spec set_role(Workspace.t(), User.t(), Membership.role()) :: :ok | {:error, :not_member}
  def set_role(%Workspace{id: workspace_id}, %User{id: user_id}, role)
      when role in [:admin, :member] do
    case Repo.update_all(
           from(m in Membership,
             where: m.workspace_id == ^workspace_id and m.user_id == ^user_id
           ),
           set: [role: role]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_member}
    end
  end

  @doc "The workspace's memberships with their users, by name."
  @spec list_memberships(Workspace.t()) :: [Membership.t()]
  def list_memberships(%Workspace{id: workspace_id}) do
    Repo.all(
      from m in Membership,
        join: u in assoc(m, :user),
        where: m.workspace_id == ^workspace_id,
        order_by: [asc: u.name],
        preload: [user: u]
    )
  end

  @doc "Removes `user` from `workspace`. Removing a non-member is a no-op."
  @spec remove_member(Workspace.t(), User.t()) :: :ok
  def remove_member(%Workspace{id: workspace_id}, %User{id: user_id}) do
    Repo.delete_all(
      from m in Membership, where: m.workspace_id == ^workspace_id and m.user_id == ^user_id
    )

    :ok
  end

  @doc """
  Creates a user and adds them to `workspace` in one step: either both happen
  or neither does.
  """
  @spec create_member(Workspace.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_member(%Workspace{} = workspace, attrs) do
    Repo.transact(fn ->
      with {:ok, user} <- PipeMaestro.Accounts.create_user(attrs),
           {:ok, _membership} <- add_member(workspace, user) do
        {:ok, user}
      end
    end)
  end
end
