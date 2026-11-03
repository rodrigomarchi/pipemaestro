defmodule ClaudeControlPlane.Accounts.Scope do
  @moduledoc """
  Who is acting and in which workspace. Every workspace-scoped call takes a
  scope, so tenant boundaries are passed explicitly rather than assumed.
  """

  alias ClaudeControlPlane.Accounts.User
  alias ClaudeControlPlane.Workspaces.Workspace

  defstruct user: nil, workspace: nil, role: nil

  @type t :: %__MODULE__{
          user: User.t() | nil,
          workspace: Workspace.t() | nil,
          role: :admin | :member | nil
        }

  @doc "A scope for `user`, outside any workspace. `nil` for an anonymous visitor."
  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  @doc "The same scope, now inside `workspace`, where the user has `role`."
  @spec put_workspace(t(), Workspace.t(), :admin | :member | nil) :: t()
  def put_workspace(%__MODULE__{} = scope, %Workspace{} = workspace, role \\ nil),
    do: %{scope | workspace: workspace, role: role}
end
