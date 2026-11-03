defmodule ClaudeControlPlane.Workspaces do
  @moduledoc """
  Workspaces (customer companies) and who belongs to them. A user may belong to
  several workspaces; membership is the only link between the two.
  """

  import Ecto.Query

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Repo
  alias ClaudeControlPlane.Workspaces.{Membership, Workspace}

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

  @doc "The workspace with `id`. Raises when there is none."
  @spec get_workspace!(Ecto.UUID.t()) :: Workspace.t()
  def get_workspace!(id), do: Repo.get!(Workspace, id)

  @doc "The workspaces `user` belongs to, by name."
  @spec list_workspaces_for_user(User.t()) :: [Workspace.t()]
  def list_workspaces_for_user(%User{id: user_id}) do
    Repo.all(
      from w in Workspace,
        join: m in assoc(w, :memberships),
        where: m.user_id == ^user_id,
        order_by: [asc: w.name]
    )
  end

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

  @doc "Adds `user` to `workspace`."
  @spec add_member(Workspace.t(), User.t()) ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def add_member(%Workspace{id: workspace_id}, %User{id: user_id}) do
    %Membership{}
    |> Membership.changeset(%{workspace_id: workspace_id, user_id: user_id})
    |> Repo.insert()
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
      with {:ok, user} <- ClaudeControlPlane.Accounts.create_user(attrs),
           {:ok, _membership} <- add_member(workspace, user) do
        {:ok, user}
      end
    end)
  end
end
